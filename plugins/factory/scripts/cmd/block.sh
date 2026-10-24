#!/usr/bin/env bash
# block — label a ticket blocked and comment the reason. The one way an agent says
# "I cannot continue without a human"; never a guess instead.
#   factory block <issue> <reason...>
set -u
# shellcheck source=../common.sh
. "$FACTORY_SCRIPTS/common.sh"
factory_require gh
N=${1:?usage: factory block <issue> <reason>}
shift
[ $# -gt 0 ] || die "usage: factory block <issue> <reason>"
factory_block_ticket "$N" "$*"
