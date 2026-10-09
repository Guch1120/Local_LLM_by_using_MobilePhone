#!/usr/bin/env bash
# Success detection (task text + last three frames) on the second camera of the same real episodes: does the result hold from another viewpoint?
cd "$(dirname "${BASH_SOURCE[0]}")"
while pgrep -f "[r]un_ident2.sh" >/dev/null; do sleep 30; done
./eval_robofac_variants.sh base_rf "" --variants tasklast3 --camera rightfront 2>&1 | grep "^tasklast3" | sed "s/^/base rightfront /"
for t in X2 X8 H1 H2; do ./eval_robofac_variants.sh ${t}_rf $t --variants tasklast3 --camera rightfront 2>&1 | grep "^tasklast3" | sed "s/^/$t rightfront /"; done
echo all done
