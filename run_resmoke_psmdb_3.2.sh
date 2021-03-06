#!/usr/bin/env bash

# Run resmoke test suites for PSMDB 3.2 

basedir=$(cd "$(dirname "$0")" || exit; pwd)
# shellcheck source=run_smoke_resmoke_funcs.sh
source "${basedir}/run_smoke_resmoke_funcs.sh"

# suite definitions - first element is suite name
# followed by runSets 

# runSets:
#   all        - run with all storage engines
#   auth       - run the suite with authentication
#   default    - run the suite with default resmoke config
#   nosuite    - run without suites option (just use args)
#   mmapv1     - run with mmapv1 storage engine
#   PerconaFT  - run with PerconaFT storage engine
#   rocksdb    - run with rocksdb storage engine
#   inMemory   - run with inMemory storage engine
#   se         - run the suite with all non-default storage engines
#   wiredTiger - run with wiredTiger storage engine
#
#
# suite name or runSets can have options specified after a space
# which are passed to resmoke.py
#
# If the suite name contains a preceeding '!' then no
# 'suites' parameter is used (just the -- style options)
#
# if the suite name's options contain --suites then that
# option will be used in place of the suite name
#
# indented lines beginning with a $ denote shell commands to run
# before the preceding suite runSets are run.

# smoke parameters
RESMOKE_JOBS=$(grep -cw ^processor /proc/cpuinfo)
RESMOKE_BASE="--continueOnFailure --jobs=${RESMOKE_JOBS} --shuffle"
RESMOKE_DEFAULT=""
RESMOKE_AUTH="--auth"
RESMOKE_SE=""

# default options for specific SE
RESMOKE_SE_DEFAULT_wiredTiger="--storageEngineCacheSizeGB=1 --excludeWithAnyTags=requires_mmapv1"
RESMOKE_SE_DEFAULT_PerconaFT=""
RESMOKE_SE_DEFAULT_rocksdb=""
RESMOKE_SE_DEFAULT_mmapv1="--storageEngineCacheSizeGB=1 --excludeWithAnyTags=requires_wiredtiger,uses_transactions,requires_document_locking,requires_majority_read_concern,uses_change_streams"
RESMOKE_SE_DEFAULT_inMemory="--storageEngineCacheSizeGB=4 --excludeWithAnyTags=requires_persistence,requires_journaling,requires_mmapv1,uses_transactions"

run_system_validations

# trial number

if [ "$1" == "" ]; then
  echo "Usage ../psmdb-misc-scripts/run_resmoke_psmdb_3.2.sh [trial #] {suite set}"
  echo "Where:"
  echo -e "\t[trial #] is a unique label for this trial test (ex. 20160901_3.2.8_01 )"
  echo -e "\t{suite set} is an optional name of suite sets to run (see psmdb-misc-scripts/suite_sets)"
  echo -e "\t\tdefault suite set is: resmoke_psmdb_3.2_default.txt"
  echo -e "\t\tif the suite set is not found in psmdb-misc-scripts/suite_sets"
  echo -e "\t\tthen script will attempt to load as absolute path."
  exit 1;
fi
trial=$1

# read suite sets

if [ -z "$2" ]; then
  suiteSet="resmoke_psmdb_3.2_default.txt"
else
  suiteSet="$2"
fi
# returns SUITES
load_suite_set "${basedir}" "${suiteSet}"


# detect storage engines
# returns DEFAULT_ENGINE, ENGINES
detectEngines

# main script

# starting from version 4.2.7 resmoke has new 'subcommand' syntax
# to execute tests from test suites we need to prepend parameters
# with 'run' command

# to detect if we need to insert 'run' try to execute resmoke with
# 'list-suites' parameter. It will succeed only on those versions
# where subcommand syntax exists

if python buildscripts/resmoke.py list-suites; then
  commandName="run"
else
  commandName=""
fi


runResmoke() {
  local resmokeParams=$1
  local logOutputFile=$2
  local suiteRawName=$3

  rm -rf "${DBPATH}/*"

  runPreprocessingCommands "${logOutputFile}" "${suiteRawName}"

  # add json output if it's not there
  if [[ ${resmokeParams} != *"reportFile"* ]]; then
    resmokeParams="${resmokeParams} --reportFile=${logOutputFile%.*}.json"
  fi

  echo "Trial: ${trial}" | tee -a "${logOutputFile}"
  echo "Base Directory: ${basedir}" | tee -a "${logOutputFile}"
  echo "Suite Set: ${suiteSet}" | tee -a "${logOutputFile}"

  echo "Running Command: buildscripts/resmoke.py ${commandName} ${resmokeParams}" | tee -a "${logOutputFile}" 
  # shellcheck disable=SC2086
  python buildscripts/resmoke.py ${commandName} ${resmokeParams} >>"${logOutputFile}" 2>&1

  if [ -f "killer.log" ]; then
    NR_KILLED=$(grep ">>> START OF PROCESS CLEANUP <<<" killer.log | wc -l)
    echo "Number of stalled tests so far: ${NR_KILLED}"
  fi
}

for suite in "${SUITES[@]}"; do

  # skip lines begining with space
  if [[ "${suite}" == " "* ]]; then
    continue; 
  fi

  IFS='|' read -r -a suiteDefinition <<< "${suite}"
  suiteElementNumber=0

  for suiteElement in "${suiteDefinition[@]}"; do

    if [[ ${suiteElement} =~ ^([a-zA-Z0-9_]+)[[:space:]](.*)$ ]]; then
      suiteElementName=${BASH_REMATCH[1]}
      suiteElementOptions=${BASH_REMATCH[2]}
    else
      suiteElementName=${suiteElement}
      suiteElementOptions=""
    fi

    if [ ${suiteElementNumber} -eq 0 ]; then

      suite=${suiteElementName}
      suiteRawName=${suite}
      suiteOptions=${suiteElementOptions}
      suiteLogTag=$(echo "${suiteElement}" | sed -r -e 's/ +/_/g' -e 's/[-!/]//g')

      if [[ "${suite}" == *"!"* ]]; then
        useSuitesOption=false
        suite=${suite#!}
        suiteOptions=$(echo ${suite}|cut -d " " -f2-)
        suite=$(echo ${suite}|cut -d " " -f1)
      elif [[ "${suiteOptions}" == *"--suites"* ]]; then
        useSuitesOption=false
      else
        useSuitesOption=true
      fi

    else

      suiteRunSet=${suiteElementName}
      suiteRunSetOptions=${suiteElementOptions}
      logOutputFilePrefix="resmoke_${suiteLogTag}_${suiteRunSet}"

      case "$suiteRunSet" in

        "default"|"auth")
          logOutputFile="${logOutputFilePrefix}_${trial}.log"
          echo "-----------------" | tee -a "${logOutputFile}"
          echo "Suite Definition: ${suiteRawName}${suiteOptions:+ ${suiteOptions}}|${suiteElement}" | tee -a "${logOutputFile}"
          [ "${suiteRunSet}" == "default" ] && resmokeParams=${RESMOKE_DEFAULT}
          [ "${suiteRunSet}" == "auth" ] && resmokeParams=${RESMOKE_AUTH}
          seDefaultOpts="RESMOKE_SE_DEFAULT_${DEFAULT_ENGINE}"
          resmokeParams="${RESMOKE_BASE} ${resmokeParams} ${!seDefaultOpts} ${suiteOptions} ${suiteRunSetOptions}"
          if $useSuitesOption; then
            resmokeParams="${resmokeParams} --suites=${suite}"
          fi
          runResmoke "${resmokeParams}" "$logOutputFile" "${suiteRawName}"

          ;;
        "wiredTiger"|"PerconaFT"|"rocksdb"|"mmapv1"|"inMemory")
          logOutputFile="${logOutputFilePrefix}_${trial}.log"
          echo "-----------------" | tee -a "${logOutputFile}"
          echo "Suite Definition: ${suiteRawName}${suiteOptions:+ ${suiteOptions}}|${suiteElement}" | tee -a "${logOutputFile}"
          if hasEngine "${suiteRunSet}"; then
            seDefaultOpts="RESMOKE_SE_DEFAULT_${suiteRunSet}"
            resmokeParams="${RESMOKE_BASE} ${RESMOKE_SE} --storageEngine=${suiteRunSet} ${!seDefaultOpts} ${suiteOptions} ${suiteRunSetOptions}"
            if $useSuitesOption; then
              resmokeParams="${resmokeParams} --suites=${suite}"
            fi
            runResmoke "${resmokeParams}" "$logOutputFile" "${suiteRawName}"
          else
            echo "failed: Storage Engine runSet: ${suiteRunSet} requested for suite ${suite} but is not available." | tee -a "${logOutputFile}"
          fi
          ;;
        "se")
          for engine in "${ENGINES[@]}"; do

            if [ ! "${engine}" == "${DEFAULT_ENGINE}" ]; then
              logOutputFile="${logOutputFilePrefix}_${engine}_${trial}.log"
              if [[ -z "${suiteRunSetOptions}" ]]; then
                suiteDefinition="${suiteRawName}|${engine}"
              else
                suiteDefinition="${suiteRawName}|${engine} ${suiteRunSetOptions}"
              fi
              echo "-----------------" | tee -a "${logOutputFile}"
              echo "Suite Definition: ${suiteDefinition}${suiteOptions:+ ${suiteOptions}}" | tee -a "${logOutputFile}"
              seDefaultOpts="RESMOKE_SE_DEFAULT_${engine}"
              resmokeParams="${RESMOKE_BASE} --storageEngine=${engine} ${RESMOKE_SE} ${!seDefaultOpts} ${suiteOptions} ${suiteRunSetOptions}"
              if $useSuitesOption; then
                resmokeParams="${resmokeParams} --suites=${suite}"
              fi
              runResmoke "${resmokeParams}" "$logOutputFile" "${suiteRawName}"
            fi
          done
          ;;
        *)
          echo "failed: Unknown runSet definition: ${suiteRunSet} for ${suite}" | tee -a "resmoke_unknown_${trial}.log"
          ;;
      esac

    fi

    ((suiteElementNumber++))

  done

done

echo "Generating summary:"

for f in $(find . -maxdepth 1 -type f \( -name "*_${trial}.log" -and -not -name "resmoke_summary_${trial}.log" \)); do
  json_file=$(echo "${f}" | sed 's:\.log$:\.json:')
  if [ $(grep -c ' Summary of ' ${f}) -eq 0 ]; then
    suite_name=$(grep "Suite Definition" ${f}|sed 's/Suite Definition: //'|sed 's:|.*::'|sed 's: .*::')
    echo "[js_test:${suite_name}] TEST SUITE HAS FAILED TO EXECUTE - PLEASE CHECK FULL LOG" >> ${f}
    echo "[resmoke] xxxx-xx-xxTxx:xx:xx.xxx+0000 ================================================================================" >> ${f}
    echo "[resmoke] xxxx-xx-xxTxx:xx:xx.xxx+0000 Summary of ${suite_name} suite: TEST SUITE HAS FAILED TO EXECUTE" >> ${f}
    echo "[resmoke] xxxx-xx-xxTxx:xx:xx.xxx+0000 ================================================================================" >> ${f}
  fi
  if [ ! -f ${json_file} ]; then
    suite_name=$(grep "Suite Definition" ${f}|sed 's/Suite Definition: //'|sed 's:|.*::'|sed 's: .*::')
    echo "{\"failures\": 1, \"results\": [{\"status\": \"fail\", \"end\": 0.0, \"exit_code\": 1, \"elapsed\": 0.0, \"start\": 0.0, \"test_file\": \"${suite_name}\"}]}" > ${json_file}
  fi
done

# shellcheck disable=SC2016
find . -maxdepth 1 -type f \( -name "*_${trial}.log" -and -not -name "resmoke_summary_${trial}.log" \) \
  -exec grep -q ' Summary of ' {} \; \
  -print \
  -exec perl -ne 'chomp;$last=$this;$this=$_;if(m/^\[resmoke\].* Summary of /){$summ=1;printf "\t$last\n"};if(m/^Running:/){$summ=0;};if($summ){printf "\t$this\n"}' {} \; \
  | tee "resmoke_summary_${trial}.log"

