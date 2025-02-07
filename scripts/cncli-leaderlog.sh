#!/usr/bin/env bash
#
# Send slots to PoolTool, write slots.csv and mail leaderlog
#
# Depending on the day of the epoch we are in (1 to 5) this script will run one
# or more of the tasks above.
# On epoch start: send slots for the current and previous epoch to PoolTool.
# On epoch day 4: calculate next epoch leaderlog, mail it and/or write slots.csv.
#
# Usage:   Via systemd timer or ./cncli-leaderlog.sh
# Author:  Leon • HAPPY Staking Pool
#
# Change the 'Pool specific variables' with values for your pool:
#  - hexStakePool: The hexadecimal hash of your pool
#  - jsonPoolTool: The config file to send slots to PoolTool (leave empty to skip).
#  - slotsCsvFile: The CSV file to write assigned slots to (leave empty to skip).
#  - mailLeaderLogsTo: The address to mail the leaderlog to (leave empty to skip).

export CARDANO_NODE_SOCKET_PATH="/var/lib/cardano/mainnet/node.socket"

# Pool specific variables
timezone="Etc/UTC"
hexStakePool=""
jsonPoolTool="/usr/local/etc/pooltool.json"
slotsCsvFile="/var/local/cncli/slots.csv"
leaderPromFile="/var/lib/prometheus/node-exporter/leaderlog.prom"
mailLeaderLogTo=""
vrfSigningKeyFile="/etc/cardano/mainnet/keys/vrf.skey"
shelleyGenesisFile="/etc/cardano/mainnet/shelley-genesis.json"
byronGenesisFile="/etc/cardano/mainnet/byron-genesis.json"
binCardanoCli="/usr/local/bin/cardano-cli"
binCnCli="/usr/local/bin/cncli"
binPython3="/usr/bin/python3"
dbCnCli="/var/local/cncli/db.sqlite"

# Script internal variables
binCardanoCliMajorVersion=$(cardano-cli --version | head -n 1 | awk '{print $2}' | cut -d'.' -f1)
secondsCardanoStart=$(date +%s -d "2017-09-23 21:44:51 +0000")
daysCardanoStart=$(( secondsCardanoStart / 86400 ))
secondsNow=$(date +%s)
daysNow=$(( secondsNow / 86400 ))
secondsSinceCardanoStart=$(( secondsNow - secondsCardanoStart ))
daysSinceCardanoStart=$(( daysNow - daysCardanoStart ))
secondsLeftInEpoch=$(( 432000 - (secondsSinceCardanoStart % 432000) ))
dayOfEpoch=$(( daysSinceCardanoStart % 5 ))
currentEpoch=$(( ( daysSinceCardanoStart - 1 ) / 5 ))

set -o pipefail

if [[ $dayOfEpoch -eq 0 ]]; then
    echo "Today is the last day of epoch ${currentEpoch}"
else
    echo "Today is day ${dayOfEpoch} of epoch ${currentEpoch}"
fi

calculateLeaderLog ()
{
    if [[ -r "${vrfSigningKeyFile}" ]];
    then
        echo -n "Calculating leaderlog for $1 (${2}) epoch... "
        poolSnapshot=$(nice -n 19 $binCardanoCli query stake-snapshot \
            --stake-pool-id $hexStakePool --mainnet)
        if [[ $? -eq 0 ]]; then echo "done"; else echo "failed!"; fi

        if [[ $binCardanoCliMajorVersion -eq 1 ]];
        then
            poolTotalStake=$(echo "$poolSnapshot" | grep -oP "(?<=    \"pool${3^}\": )\d+(?=,?)")
            poolActiveStake=$(echo "$poolSnapshot" | grep -oP "(?<=    \"active${3^}\": )\d+(?=,?)")
        else
            stakeNumbers=$(echo "$poolSnapshot" | grep -oP "(?<=    \"$3\": )\d+(?=,?)")
            poolTotalStake=$(echo $stakeNumbers | cut -d' ' -f1)
            poolActiveStake=$(echo $stakeNumbers | cut -d' ' -f2)
        fi

        $binCnCli leaderlog \
            --db $dbCnCli --pool-id $hexStakePool --pool-vrf-skey $vrfSigningKeyFile \
            --byron-genesis $byronGenesisFile --shelley-genesis $shelleyGenesisFile \
            --pool-stake $poolTotalStake --active-stake $poolActiveStake \
            --tz $timezone --ledger-set ${1} > /tmp/leaderlog
    else
        echo "The VRF signing key file is not readable."
        exit 1
    fi
}

mailLeaderLog ()
{
    if [[ "${mailLeaderLogTo}" != "" && -r "/tmp/leaderlog" ]];
    then
        echo -n "Mailing leaderlog to ${mailLeaderLogTo}... "
        cat /tmp/leaderlog | jq | mail -s "Leaderlog for $1 epoch (${2})" -- $mailLeaderLogTo
        if [[ $? -eq 0 ]]; then echo "done"; else echo "failed!"; fi
    else
        echo "Not mailing leaderlog"
    fi
}

sendPoolToolSlots ()
{
    if [[ "${jsonPoolTool}" != "" && -r "${jsonPoolTool}" ]];
    then
        echo -n "Retrieving CNCLI database status... "
        status=$(${binCnCli} status --db ${dbCnCli} --byron-genesis ${byronGenesisFile} \
            --shelley-genesis ${shelleyGenesisFile} | jq -r '.status' )
        if [[ "${status}" == "error" ]]; then echo "failed!"; echo "${status}"; else echo "done"; fi

        if [[ "${status}" == "ok" ]];
        then
            echo -n "Sending slots to PoolTool... "
            result=$(${binCnCli} sendslots --db ${dbCnCli} --byron-genesis ${byronGenesisFile} \
                --shelley-genesis ${shelleyGenesisFile} --config ${jsonPoolTool})
            if [[ "${result}" == "error" ]]; then echo "failed!"; echo "${result}"; else echo "done"; fi
        fi
    else
        echo "Not sending slots to PoolTool"
    fi
}

writeLeaderSlots ()
{
    if [[ "${slotsCsvFile}" != "" && -w `dirname "${slotsCsvFile}"` && `jq -r '.status' <<< "$(cat /tmp/leaderlog)"` == "ok" ]];
    then
        echo -n "Writing leaderlog to ${slotsCsvFile}... "
        cat /tmp/leaderlog | jq -r '.assignedSlots[] | (.at|strptime("%Y-%m-%dT%H:%M:%S%z")|strftime("%Y-%m-%d %T")) + "," + (.slot|tostring) + "," + (.no|tostring)' > $slotsCsvFile
        sed -i '1i Time,Slot,No' $slotsCsvFile
        if [[ $? -eq 0 ]]; then echo "done"; else echo "failed!"; fi
    else
        echo "Not writing slots.csv"
    fi
}

# Run within 10 minutes of epoch start
if [[ $dayOfEpoch -eq 0 && $secondsLeftInEpoch -lt 432000 && $secondsLeftInEpoch -gt 431400 ]];
writeLeaderProm ()
{
    if [[ "${leaderPromFile}" != "" && -w `dirname "${leaderPromFile}"` && `jq -r '.status' <<< "$(cat /tmp/leaderlog)"` == "ok" ]];
    then
        echo -n "Writing leaderlog prom data to ${leaderPromFile}... "
        printf "assigned_blocks_epoch %d\n" `cat /tmp/leaderlog | jq -r '.epochSlots'` > $leaderPromFile
        if [[ $? -eq 0 ]]; then echo "done"; else echo "failed!"; fi
    else
        echo "Not writing leaderlog.prom"
    fi
}

# Run within 10 minutes of epoch start
if [[ $dayOfEpoch -eq 1 ]];
then
    calculateLeaderLog prev $(($currentEpoch-1)) stakeGo
    calculateLeaderLog current $currentEpoch stakeSet
    sendPoolToolSlots
fi

# Run as soon as the leaderlog is available
if [[ $dayOfEpoch -eq 4 && $secondsLeftInEpoch -le 129600 && $secondsLeftInEpoch -gt 84600 || -n $1 ]];
then
    calculateLeaderLog next $(($currentEpoch+1)) stakeMark
    mailLeaderLog next $(($currentEpoch+1))
    writeLeaderSlots
fi
