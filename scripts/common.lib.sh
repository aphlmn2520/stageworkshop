#!/usr/bin/env bash

function NTNX_Download
{
  local _META_URL="http://download.nutanix.com/"
  local  _VERSION=1

  if [[ ${1} == 'PC' ]]; then
    CheckArgsExist 'PC_VERSION'

    # When adding a new PC version, update BOTH case stanzas below...
    case ${PC_VERSION} in
      5.9 | 5.6.2 | 5.8.0.1 )
        _VERSION=2
        ;;
    esac

    _META_URL=+"pc/one-click-pc-deployment/${PC_VERSION}/v${_VERSION}/"
    case ${PC_VERSION} in
      5.9 )
        _META_URL+="euphrates-${PC_VERSION}-stable-prism_central_one_click_deployment_metadata.json"
        ;;
      5.6.1 | 5.6.2 )
        _META_URL+="euphrates-${PC_VERSION}-stable-prism_central_metadata.json"
        ;;
      5.7.0.1 | 5.7.1 | 5.7.1.1 )
        _META_URL+="pc-${PC_VERSION}-stable-prism_central_metadata.json"
        ;;
      5.8.0.1 | 5.8.1 | 5.8.2 | 5.10 | 5.11 )
        _META_URL+="pc_deploy-${PC_VERSION}.json"
        ;;
      * )
        _ERROR=22
        log "Error ${_ERROR}: unsupported PC_VERSION=${PC_VERSION}!"
        log 'Browse to https://portal.nutanix.com/#/page/releases/prismDetails'
        log " - Find ${PC_VERSION} in the Additional Releases section on the lower right side"
        log ' - Provide the metadata URL for the "PC 1-click deploy from PE" option to this function, both case stanzas.'
        exit ${_ERROR}
        ;;
    esac
  else
    CheckArgsExist 'AOS_VERSION AOS_UPGRADE'

    # When adding a new AOS version, update BOTH case stanzas below...
    case ${AOS_UPGRADE} in
      5.8.0.1 )
        _VERSION=2
        ;;
      5.9 )
        _VERSION=0
        ;;
    esac

    _META_URL+="/releases/euphrates-${AOS_UPGRADE}-metadata/"

    if (( $_VERSION > 0 )); then
      _META_URL+="v${_VERSION}/"
    fi

    case ${AOS_UPGRADE} in
      5.8.0.1 | 5.9 )
        _META_URL+="euphrates-${AOS_UPGRADE}-metadata.json"
        ;;
      * )
        _ERROR=23
        log "Error ${_ERROR}: unsupported AOS_UPGRADE=${AOS_UPGRADE}!"
        # TODO: correct AOS_UPGRADE URL
        log 'Browse to https://portal.nutanix.com/#/page/releases/nosDetails'
        log " - Find ${AOS_UPGRADE} in the Additional Releases section on the lower right side"
        log ' - Provide the Upgrade metadata URL to this function for both case stanzas.'
        exit ${_ERROR}
        ;;
    esac
  fi

  if [[ ! -e ${_META_URL##*/} ]]; then
    log "Retrieving download metadata ${_META_URL} ..."
    Download "${_META_URL}"
  else
    log "Warning: using cached download ${_META_URL##*/}"
  fi

  _SOURCE_URL=$(cat ${_META_URL##*/} | jq -r .download_url_cdn)

  if (( `pgrep curl | wc --lines | tr -d '[:space:]'` > 0 )); then
    pkill curl
  fi
  log "Retrieving Nutanix ${1} bits..."
  Download "${_SOURCE_URL}"

  local _CHECKSUM=$(md5sum ${_SOURCE_URL##*/} | awk '{print $1}')
  if [[ `cat ${_META_URL##*/} | jq -r .hex_md5` != ${_CHECKSUM} ]]; then
    log "Error: md5sum ${_CHECKSUM} doesn't match on: ${_SOURCE_URL##*/} removing and exit!"
    rm -f ${_SOURCE_URL##*/}
    exit 2
  else
    log "Success: bits downloaded and passed MD5 checksum!"
  fi

  # Set globals for next steps
    META_URL=${_META_URL}
  SOURCE_URL=${_SOURCE_URL}
}

function log {
  local CALLER=$(echo -n `caller 0 | awk '{print $2}'`)
  echo $(date "+%Y-%m-%d %H:%M:%S")"|$$|${CALLER}|${1}"
}

function TryURLs {
  #TODO: trouble passing an array to this function
  HTTP_CODE=$(curl ${CURL_OPTS} --write-out %{http_code} --head ${1} | tail -n1)
  #log ${HTTP_CODE}
}

function CheckArgsExist {
  local _ARGUMENT
  local    _ERROR=88
  for _ARGUMENT in ${1}; do
    if [[ ${DEBUG} ]]; then
      log "DEBUG: Checking ${_ARGUMENT}..."
    fi
    _RESULT=$(eval "echo \$${_ARGUMENT}")
    if [[ -z ${_RESULT} ]]; then
      log "Error ${_ERROR}: ${_ARGUMENT} not provided!"
      exit ${_ERROR}
    elif [[ ${DEBUG} ]]; then
      log "Non-error: ${_ARGUMENT} for ${_RESULT}"
    fi
  done
  if [[ ${DEBUG} ]]; then
    log 'Success: required arguments provided.'
  fi
}

function SSH_PubKey {
  local   _NAME=${MY_EMAIL//\./_DOT_}
  local _SSHKEY=${HOME}/id_rsa.pub
  _NAME=${_NAME/@/_AT_}
  if [[ -e ${_SSHKEY} ]]; then
    log "Note that a period and other symbols aren't allowed to be a key name."
    log "Locally adding ${_SSHKEY} under ${_NAME} label..."
    ncli cluster add-public-key name=${_NAME} file-path=${_SSHKEY}
  fi
}

function Determine_PE {
  log 'Warning: expect errors on lines 1-2, due to non-JSON outputs by nuclei...'
  local _HOLD=$(nuclei cluster.list format=json \
    | jq '.entities[] | select(.status.state == "COMPLETE")' \
    | jq '. | select(.status.resources.network.external_ip != null)')

  if (( $? > 0 )); then
    log "Error: couldn't resolve clusters $?"
    exit 10
  else
    export CLUSTER_NAME=$(echo ${_HOLD} | jq .status.name | tr -d \")
    export   MY_PE_HOST=$(echo ${_HOLD} | jq .status.resources.network.external_ip | tr -d \")

    log "Success: ${CLUSTER_NAME} PE external IP=${MY_PE_HOST}"
  fi
}

function Download {
  local           _ATTEMPTS=5
  local              _ERROR=0
  local _HTTP_RANGE_ENABLED='--continue-at -'
  local               _LOOP=0
  local             _OUTPUT=''
  local              _SLEEP=2

  if [[ -z ${1} ]]; then
    _ERROR=33
    log "Error ${_ERROR}: no URL to download!"
    exit ${_ERROR}
  fi

  while true ; do
    (( _LOOP++ ))
    log "${1}..."
    _OUTPUT=''
    # curl ${CURL_OPTS} ${_HTTP_RANGE_ENABLED} --remote-name --location ${1}
    curl ${CURL_OPTS} --remote-name --location ${1}
    _OUTPUT=$?
    #DEBUG=1; if [[ ${DEBUG} ]]; then log "DEBUG: curl exited ${_OUTPUT}."; fi

    if (( ${_OUTPUT} == 0 )); then
      log "Success: ${1##*/}"
      break
    fi

    if (( ${_LOOP} == ${_ATTEMPTS} )); then
      log "Error: couldn't download from: ${1}, giving up after ${_LOOP} tries."
      exit 11
    elif (( ${_OUTPUT} == 33 )); then
      log "Web server doesn't support HTTP range command, purging and falling back."
      _HTTP_RANGE_ENABLED=''
      rm -f ${1##*/}
    else
      log "${_LOOP}/${_ATTEMPTS}: curl=${_OUTPUT} ${1##*/} SLEEP ${_SLEEP}..."
      sleep ${_SLEEP}
    fi
  done
}

function remote_exec {
# Argument ${1} = REQIRED: ssh or scp
# Argument ${2} = REQIRED: PE, PC, or LDAP_SERVER
# Argument ${3} = REQIRED: command configuration
# Argument ${4} = OPTIONAL: populated with anything = allowed to fail

  local  _ACCOUNT='nutanix'
  local _ATTEMPTS=3
  local    _ERROR=99
  local     _HOST
  local     _LOOP=0
  local _PASSWORD="${MY_PE_PASSWORD}"
  local   _PW_INIT='nutanix/4u' # TODO:140 hardcoded p/w
  local    _SLEEP=${SLEEP}
  local     _TEST=0

  case ${2} in
    'PE' )
          _HOST=${MY_PE_HOST}
      ;;
    'PC' )
          _HOST=${MY_PC_HOST}
      _PASSWORD=${_PW_INIT}
      ;;
    'LDAP_SERVER' )
       _ACCOUNT='root'
          _HOST=${LDAP_HOST}
      _PASSWORD=${_PW_INIT}
         _SLEEP=7
      ;;
  esac

  if [[ -z ${3} ]]; then
    log 'Error ${_ERROR}: missing third argument.'
    exit ${_ERROR}
  fi

  if [[ ! -z ${4} ]]; then
    _ATTEMPTS=1
       _SLEEP=0
  fi

  while true ; do
    (( _LOOP++ ))
    case "${1}" in
      'SSH' | 'ssh')
       #DEBUG=1; if [[ ${DEBUG} ]]; then log "_TEST will perform ${_ACCOUNT}@${_HOST} ${3}..."; fi
        SSHPASS="${_PASSWORD}" sshpass -e ssh -x ${SSH_OPTS} ${_ACCOUNT}@${_HOST} "${3}"
        _TEST=$?
        ;;
      'SCP' | 'scp')
        #DEBUG=1; if [[ ${DEBUG} ]]; then log "_TEST will perform scp ${3} ${_ACCOUNT}@${_HOST}:"; fi
        SSHPASS="${_PASSWORD}" sshpass -e scp ${SSH_OPTS} ${3} ${_ACCOUNT}@${_HOST}:
        _TEST=$?
        ;;
      *)
        log "Error ${_ERROR}: improper first argument, should be ssh or scp."
        exit ${_ERROR}
        ;;
    esac

    if (( ${_TEST} > 0 )) && [[ -z ${4} ]]; then
      _ERROR=22
      log "Error ${_ERROR}: pwd=`pwd`, _TEST=${_TEST}, _HOST=${_HOST}"
      exit ${_ERROR}
    fi

    if (( ${_TEST} == 0 )); then
      if [[ ${DEBUG} ]]; then log "${3} executed properly."; fi
      return 0
    elif (( ${_LOOP} == ${_ATTEMPTS} )); then
      if [[ -z ${4} ]]; then
        _ERROR=11
        log "Error ${_ERROR}: giving up after ${_LOOP} tries."
        exit ${_ERROR}
      else
        log "Optional: giving up."
        break
      fi
    else
      log "${_LOOP}/${_ATTEMPTS}: _TEST=$?|${_TEST}| ${FILENAME} SLEEP ${_SLEEP}..."
      sleep ${_SLEEP}
    fi
  done
}

function Dependencies {
  local _ERROR
  local _CPE=/etc/os-release # CPE = https://www.freedesktop.org/software/systemd/man/os-release.html
  local _LSB=/etc/lsb-release #Linux Standards Base

  if [[ -z ${1} ]]; then
    _ERROR=20
    log "Error ${_ERROR}: missing install or remove verb."
    exit ${_ERROR}
  elif [[ -z ${2} ]]; then
    _ERROR=21
    log "Error ${_ERROR}: missing package name."
    exit ${_ERROR}
  fi

  case "${1}" in
    'install')
      log "Install ${2}..."
      export PATH=${PATH}:${HOME}
      if [[ -z `which ${2}` ]]; then
        case "${2}" in
          sshpass )
            if [[ -e ${_LSB} && `grep DISTRIB_ID ${_LSB} | awk -F= '{print $2}'` == 'Ubuntu' ]]; then
              sudo apt-get install --yes sshpass
            elif [[ -e ${_CPE} && `grep '^ID=' ${_CPE} | awk -F= '{print $2}' ` == '"centos"' ]]; then
              # TOFIX: assumption, probably on NTNX CVM or PCVM = CentOS7
              if [[ ! -e sshpass-1.06-2.el7.x86_64.rpm ]]; then
                Download http://mirror.centos.org/centos/7/extras/x86_64/Packages/sshpass-1.06-2.el7.x86_64.rpm
              fi
              sudo rpm -ivh sshpass-1.06-2.el7.x86_64.rpm
              if (( $? > 0 )); then
                _ERROR=31
                log "Error ${_ERROR}: cannot install ${2}."
                exit ${_ERROR}
              fi
              # https://pkgs.org/download/sshpass
              # https://sourceforge.net/projects/sshpass/files/sshpass/
            elif [[ `uname -s` == "Darwin" ]]; then
              brew install https://raw.githubusercontent.com/kadwanev/bigboybrew/master/Library/Formula/sshpass.rb
            fi
            ;;
          jq )
            if [[ -e ${_LSB} && `grep DISTRIB_ID ${_LSB} | awk -F= '{print $2}'` == 'Ubuntu' ]]; then
              if [[ ! -e jq-linux64 ]]; then
                sudo apt-get install --yes jq
              fi
            elif [[ -e ${_CPE} && `grep '^ID=' ${_CPE} | awk -F= '{print $2}'` == '"centos"' ]]; then
              # https://stedolan.github.io/jq/download/#checksums_and_signatures
              if [[ ! -e jq-linux64 ]]; then
                Download https://github.com/stedolan/jq/releases/download/jq-1.5/jq-linux64
              fi
              chmod u+x jq-linux64 && ln -s jq-linux64 jq
              export PATH+=:`pwd`
            elif [[ `uname -s` == "Darwin" ]]; then
              brew install jq
            fi
            ;;
        esac

        if (( $? > 0 )); then
          _ERROR=98
          log "Error ${_ERROR}: can't install ${2}."
          exit ${_ERROR}
        fi
      else
        log "Success: found ${2}."
      fi
      ;;
    'remove')
      log "Removing ${2}..."
      if [[ -e ${_CPE} && `grep '^ID=' ${_CPE} | awk -F= '{print $2}'` == '"centos"' ]]; then
        #TODO:30 assuming we're on PC or PE VM.
        case "${2}" in
          sshpass )
            sudo rpm -e sshpass
            ;;
          jq )
            rm -f jq jq-linux64
            ;;
        esac
      else
        log "Feature: don't remove Dependencies on Mac OS Darwin or Ubuntu."
      fi
      ;;
  esac
}

function Check_Prism_API_Up {
# Argument ${1} = REQUIRED: PE or PC
# Argument ${2} = OPTIONAL: number of attempts
# Argument ${3} = OPTIONAL: number of seconds per cycle
  local _ATTEMPTS=${ATTEMPTS}
  local    _ERROR=77
  local     _HOST
  local     _LOOP=0
  local _PASSWORD="${MY_PE_PASSWORD}"
  local  _PW_INIT='Nutanix/4u'
  local    _SLEEP=${SLEEP}
  local     _TEST=0

  CheckArgsExist 'ATTEMPTS MY_PE_PASSWORD SLEEP'

  if [[ ${1} == 'PC' ]]; then
    _HOST=${MY_PC_HOST}
  else
    _HOST=${MY_PE_HOST}
  fi
  if [[ ! -z ${2} ]]; then
    _ATTEMPTS=${2}
  fi

  while true ; do
    (( _LOOP++ ))
    _TEST=$(curl ${CURL_HTTP_OPTS} --user ${PRISM_ADMIN}:${_PASSWORD} \
      -X POST --data '{ "kind": "cluster" }' \
      https://${_HOST}:9440/api/nutanix/v3/clusters/list \
      | tr -d \") # wonderful addition of "" around HTTP status code by cURL

    if [[ ! -z ${3} ]]; then
      _SLEEP=${3}
    fi

    if (( ${_TEST} == 401 )); then
      log "Warning: unauthorized ${1} user or password."
    fi

    if (( ${_TEST} == 401 )) && [[ ${1} == 'PC' ]] && [[ ${_PASSWORD} != ${_PW_INIT} ]]; then
      _PASSWORD=${_PW_INIT}
      log "Warning @${1}: Fallback on ${_HOST}: try initial password next cycle..."
      _SLEEP=0 #break
    fi

    if (( ${_TEST} == 200 )); then
      log "@${1}: successful."
      return 0
    elif (( ${_LOOP} > ${_ATTEMPTS} )); then
      log "Warning ${_ERROR} @${1}: Giving up after ${_LOOP} tries."
      return ${_ERROR}
    else
      log "@${1} ${_LOOP}/${_ATTEMPTS}=${_TEST}: sleep ${_SLEEP} seconds..."
      sleep ${_SLEEP}
    fi
  done
}
