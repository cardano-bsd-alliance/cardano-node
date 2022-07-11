usage_app() {
     usage "app" "Multi-container application" <<EOF
    compose               Multi-container description file

EOF
}

app() {
  local op=${1:-show}; test $# -gt 0 && shift

  case "$op" in

    # wb app compose $WORKBENCH_SHELL_PROFILE_DIR/{profile,node-specs}.json name tag
    compose )
      # jq 'keys|.[]' --raw-output $WORKBENCH_SHELL_PROFILE_DIR/node-specs.json
      local usage="USAGE: wb app $op PROFILE-NAME/JSON NODE-SPECS/JSON IMAGE_NAME IMAGE_TAG"
      local profile=${1:?$usage}
      local nodespecs=${2:?$usage}
      local imageName=${3:?$usage}
      local imageTag=${4:?$usage}

      # Hack
      global_rundir_def=$PWD/run

      yq --yaml-output "{
        services:
          (
              .
            | with_entries(
                {
                    key: .key
                  , value: {
                        container_name: \"\(.value.name)\"
                      , pull_policy: \"never\"
                      , image: \"$imageName:$imageTag\"
                      , networks: {
                          \"cardano-node-network\": {
                            ipv4_address: \"172.22.\(.value.i / 254 | floor).\(.value.i % 254 + 1)\"
                          }
                        }
                      , ports: [\"\(.value.port):\(.value.port)\"]
                      , volumes: [
                            \"SHARED:/var/cardano-node\"
                          , \"LOCAL-\(.value.name):/var/cardano-node/local\"
                        ]
                      , environment: [
                            \"HOST_ADDR=172.22.\(.value.i / 254 | floor).\(.value.i % 254 + 1)\"
                          , \"PORT=\(.value.port)\"
                          , \"DATA_DIR=/var/cardano-node/local\"
                          , \"NODE_CONFIG=/var/cardano-node/local/config.json\"
                          , \"NODE_TOPOLOGY=/var/cardano-node/local/topology.json\"
                          , \"SOCKET_PATH=/var/cardano-node/local/node.socket\"
                          , \"RTS_FLAGS=+RTS -N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return -RTS\"
                          , \"SHELLEY_KES_KEY=/var/cardano-node/local/../genesis/node-keys/node-kes\(.value.i).skey\"
                          , \"SHELLEY_VRF_KEY=/var/cardano-node/local/../genesis/node-keys/node-vrf\(.value.i).skey\"
                          , \"SHELLEY_OPCERT=/var/cardano-node/local/../genesis/node-keys/node\(.value.i).opcert\"
                        ]
                    }
                }
              )
          )
        , \"networks\": {
          \"cardano-node-network\": {
              external: false
            , attachable: true
            , driver: \"bridge\"
            , driver_opts: {}
            , enable_ipv6: false
            , ipam: {
                driver: \"default\"
              , config: [{
                  subnet: \"172.22.0.0/16\"
                , ip_range: \"172.22.0.0/16\"
                , gateway: \"172.22.255.254\"
                , aux_addresses: {}
              }]
            }
          }
        }
        , volumes:
          (
              .
            | with_entries (
                {
                    key: \"LOCAL-\(.value.name)\"
                  , value: {
                        external: false
                      , driver_opts: {
                            type: \"none\"
                          , o: \"bind\"
                          , device: \"./run/\${WB_RUNDIR_TAG:-current}/\(.value.name)\"
                        }
                    }
                }
              )
            +
              {SHARED:
                {
                    external: false
                  , driver_opts: {
                        type: \"none\"
                      , o: \"bind\"
                      , device: \"./run/\${WB_RUNDIR_TAG:-current}\"
                    }
                }
              }
          )
      }" $nodespecs;;

    * ) usage_app;; esac
}
