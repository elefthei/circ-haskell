set -ex
CIRCIFY=$(which compiler-exe)
SCRIPT_PATH="${0:A:h}"

# 1 argument: benchmark name
# 2 argument: compiler
# 3 argument: number of constraints
function save_result() {
    echo $1,$2,$3 >> $SCRIPT_PATH/results-wip.csv
}

function init_results() {
    rm -rf $SCRIPT_PATH/results-wip.csv
    echo benchmark,compiler,constraints > $SCRIPT_PATH/results-wip.csv
}

function commit_results() {
    mv $SCRIPT_PATH/results-wip.csv $SCRIPT_PATH/results.csv
}

# 1 argument: c path
# 2 argument: compiler
# 3 argument: benchmark name
function count() {
    d=$(mktemp -d -p . )
    cd $d
    case $2 in
    circify)
        C_pequin_io=True C_no_overflow=True env $e $CIRCIFY c-emit-r1cs compute $1
        n=$(head -n 1 C | awk '{print $3}')
        ;;
    *)
        echo "Unknown circom compiler: $2"
        exit 1
        ;;
    esac
    cd -
    save_result $3 $2 $n
    rm -rf $d
}
typeset -A paths
paths=(
    mm5
             ~/repos/llcl/compiler/mm_flat_5.c
    u32sqrt
             ~/repos/llcl/compiler/test/Code/C/sqrt.c
    ptrs
             ~/repos/llcl/compiler/test/Code/C/pequin/ptrchase_8_8.c
    ptrs-benes
             ~/repos/llcl/compiler/test/Code/C/pequin/ptrchase_8_8.c
         )
typeset -A envvars
envvars=(
    mm5
             ""
    u32sqrt
             ""
    ptrs
             ""
    ptrs-benes
             "C_smt_benes_thresh=7"
         )

init_results
for b in "${(@k)paths}"; do
    p="${paths[$b]}"
    e="${envvars[$b]}"
    for compiler in circify; do
        count $p $compiler $b "$e"
    done
done
commit_results
cat ./pequin_results.csv | tail -n +2 >> results.csv
