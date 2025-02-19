ODIN=~/opt/Odin/odin

set -xe

MAX_ITER=${MAX_ITER:-400}
CELL_SIZE=${CELL_SIZE:-8}
shader=mandelbrot.comp
glslc $shader -o $shader.spv -DCELL_SIZE=$CELL_SIZE -DMAX_ITER=$MAX_ITER

case "$1" in
    "check")
        $ODIN check . -vet -strict-style;;
    "release")
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -o:speed -out:mandelbrot-release;;
    *)
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -out:mandelbrot-debug;;
esac
