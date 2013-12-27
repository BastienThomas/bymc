#!/bin/bash
#
# Function specific to nusmv
#
# Igor Konnov, 2013

DEPTH=${DEPTH:-10} # parse options?

. $BYMC_HOME/script/mod-verify-nusmv-common.sh

function mc_compile_first {
    common_mc_compile_first
}

function mc_verify_spec {
    SCRIPT="script.nusmv"
    echo "set on_failure_script_quits" >$SCRIPT
    echo "go_bmc" >>$SCRIPT
    echo "time" >>$SCRIPT
    if grep -q "INVARSPEC NAME ${PROP}" "${SRC}"; then
        echo "check_invar_bmc -k $DEPTH -a een-sorensson -P ${PROP}" \
            >>${SCRIPT}
    else
        if [ "$ONE_SHOT" != "1" ]; then
            echo "check_ltlspec_bmc_inc -k $DEPTH -P ${PROP}" >>${SCRIPT}
        else
            echo "check_ltlspec_bmc_onepb -k $DEPTH -P ${PROP}" >>${SCRIPT}
        fi
    fi
    echo "time" >>$SCRIPT
    echo "show_traces -v -o ${CEX}" >>${SCRIPT}
    echo "quit" >>${SCRIPT}

    rm -f ${CEX}
    tee_or_die "$MC_OUT" "nusmv failed"\
        $TIME ${NUSMV} -df -v $NUSMV_VERBOSE -source "${SCRIPT}" "${SRC}"
    # the exit code of grep is the return code
    if [ '!' -f ${CEX} ]; then
        echo ""
        echo "No counterexample found with bounded model checking."
        echo "WARNING: To guarantee completeness, make sure that DEPTH is set properly"
        echo "as per completeness threshold"
        echo ""
        true
    else
        echo "Specification is violated." >>$MC_OUT
        false
    fi
}

function mc_refine {
    echo "mc_refine"
    common_mc_refine
}

function mc_collect_stat {
    res=$(common_mc_collect_stat)
    mc_stat="$res|technique=nusmv-bmc"
}
