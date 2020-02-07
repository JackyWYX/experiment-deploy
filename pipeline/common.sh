# to be sourced by other scripts, no shebang is needed
# it requires bash 4.x to work as we used array here
# use 'base -version' to check the version

unset -v PROGDIR
case "${0}" in
*/*) PROGDIR="${0%/*}";;
*) PROGDIR=.;;
esac

ROOTDIR=${PROGDIR}/..
CONFIG_DIR=$(realpath $ROOTDIR)/configs
JQ='jq -M -r'

declare -A configs
declare -A managednodes
declare -a genesis
declare -a blskey

REGIONS=( nrt sfo iad pdx fra sin cmh dub )

function expense
{
   local step=$1
   local duration=$SECONDS
   logging $step took $(( $duration / 60 )) minutes and $(( $duration % 60 )) seconds
}

function verbose
{
   [ $VERBOSE ] && echo $@
}

function errexit
{
   logging "$@ . Exiting ..."
   exit -1
}

function _join
{
   local IFS="$1"; shift; echo "$*"; 
}

function logging
{
   echo $(date) : $@
   SECONDS=0
}

function read_profile
{
   BENCHMARK_PROFILE=$1
   [ ! -e $BENCHMARK_PROFILE ] && errexit "can't find the benchmark config file: $BENCHMARK_PROFILE"

   logging reading benchmark config file: $BENCHMARK_PROFILE

   keys=(
      description libp2p genesis aws.profile azure.num_vm azure.regions
      leader.regions leader.num_vm leader.type leader.root leader.protection
      explorer_node.regions explorer_node.num_vm explorer_node.type explorer_node.root explorer_node.protection
      client.regions client.num_vm client.type
      benchmark.shards benchmark.duration benchmark.dashboard benchmark.crosstx
      benchmark.attacked_mode benchmark.init_retry
      logs.leader logs.client logs.validator logs.soldier logs.db
      parallel
      userdata flow.wait_for_launch flow.reserved_account flow.rpczone flow.rpcnode
      benchmark.minpeer benchmark.even_shard benchmark.peer_per_shard
      benchmark.commit_delay benchmark.log_conn benchmark.network_type
      explorer.name explorer.port explorer.reset
      explorer2.name explorer2.port explorer2.reset
      txgen.ip txgen.port txgen.enable
      bootnode.port bootnode.server bootnode.key bootnode.enable bootnode.p2pkey
      bootnode.log_conn
      bootnode1.port bootnode1.server bootnode1.key bootnode1.enable
      bootnode1.p2pkey bootnode1.log_conn
      bootnode3.port bootnode3.server bootnode3.key bootnode3.enable
      bootnode3.p2pkey bootnode3.log_conn
      bootnode4.port bootnode4.server bootnode4.key bootnode4.enable
      bootnode4.p2pkey bootnode4.log_conn
      wallet.enable
      benchmark.bls bls.pass bls.bucket bls.folder bls.keyfile
      multikey.enable multikey.keys_per_node multikey.blskey_folder
   )
   
   managednodekey=.managednodes.nodes
   nodekeys=( role ip port key )

   for k in ${keys[@]}; do
      configs[$k]=$($JQ .$k $BENCHMARK_PROFILE)
   done

   # set some default value
   [ "${configs[leader.protection]}" == "null" ] && configs[leader.protection]=false
   [ "${configs[explorer_ndoe.protection]}" == "null" ] && configs[explorer_node.protection]=false

   nodes_num=$($JQ " $managednodekey | length " $BENCHMARK_PROFILE)
   configs[managednodes.num]=$nodes_num
   i=0
   while [ $i -lt $nodes_num ]; do
      for k in ${nodekeys[@]}; do
         configs[managednode$i.$k]=$($JQ " $managednodekey[$i].$k " $BENCHMARK_PROFILE)
      done
      ((i++))
   done

   if [ "${configs[genesis]}" != "null" ]; then
      genesis=( $(cat $CONFIG_DIR/${configs[genesis]}) )
   fi

   if [ "${configs[bls.keyfile]}" != "null" ]; then
      blskey=( $(cat $CONFIG_DIR/${configs[bls.keyfile]}) )
   fi

}

function gen_userdata
{
   BUCKET=$1
   FOLDER=$2
   USERDATA=$3

   [ ! -e $USERDATA ] && errexit "can't find userdata file: $USERDATA"

   echo "generating userdata file"
   sed "-e s,^BUCKET=.*,BUCKET=${BUCKET}," -e "s,^FOLDER=.*,FOLDER=${FOLDER}," $USERDATA > $USERDATA.aws
   verbose ${configs[@]}
}

# gen_multi_key generates a list of index that can be used to add multiple keys to one node
# the algorithm is trying to separate the index as much as possible
#
# INPUT parameters
# * number of shards
# * number of nodes per shard
# * number of bls keys
# * shard number of the node
# * generate the list of index for the nth node to number of
#
# OUTPUT: a list of index for one node with multi-key
function gen_multi_key
{
   shard=$1
   num_nodes=$2
   keys_per_node=$3

   s=$4
   n=$5

# total number of nodes
   total=$(( $shard * $num_nodes ))

# gap among multi-key
   gap=$(( $num_nodes / $keys_per_node ))

# number of multi-key nodes, considering left over nodes
   if [ $(( $num_nodes % $keys_per_node )) -eq 0 ]; then
      mk_nodes=$gap
   else
      mk_nodes=$(( $gap + 1 ))
      remainder=true
   fi

# is this node the last one?
# differernt starting index
   lastone=false
   if [[ "$remainder" == "true" && $n -eq $(( $mk_nodes - 1 )) ]]; then
      lastone=true
      start=$(( $gap * $shard * $keys_per_node + $s ))
   else
      start=$(( $shard * $n + $s ))
   fi

# enumerate the multi-key for this node
# FIXME: for the last node, just have all remaining keys
# this is not ideal allocation algorithm for the last one though
   i=1
   keys=( $start )
   while [ $i -lt $keys_per_node ]; do
      if [ "$lastone" == "true" ]; then
         start=$(( $start + $shard ))
      else
         start=$(( $start + $gap * $shard ))
      fi
      if [ $start -lt $total ]; then
         keys+=( $start )
      fi
      (( i++ ))
   done

# return the list of keys for one node
   echo ${keys[@]}
}

##########

if [ "$(uname -s)" == "Darwin" ]; then
   TIMEOUT=gtimeout
else
   TIMEOUT=timeout
fi

if [ "$WHOAMI" == "ec2-user" ]; then
   errexit "please set WHOAMI variable, can't use ec2-user"
fi
