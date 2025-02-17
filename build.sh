ODIN=~/opt/Odin/odin

set -xe

CELL_SIZE=${CELL_SIZE:-8}
shader=mandelbrot.comp
glslc $shader -o $shader.spv -DCELL_SIZE=$CELL_SIZE

case "$1" in
    "check")
        $ODIN check . -vet -strict-style;;
    "release")
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -o:speed -out:mandelbrot-release;;
    *)
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -out:mandelbrot-debug;;
esac
