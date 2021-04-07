#!/usr/bin/env bash

export CARDANO_NODE_SOCKET_PATH="/home/cardano-node/socket/node.socket"

/usr/local/bin/cardano-cli query ledger-state --mainnet > /root/scripts/ledger-state.json

exit 0
