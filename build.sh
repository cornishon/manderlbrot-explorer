ODIN=~/opt/Odin/odin

set -xe

for shader in shader.{frag,vert}; do
    glslc $shader -o $shader.spv
done

CELL_SIZE=${CELL_SIZE:-8}
shader=mandelbrot.comp
glslc $shader -o $shader.spv -DCELL_SIZE=$CELL_SIZE

case "$1" in
    "check")
        $ODIN check . -vet -strict-style;;
    "release")
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -o:speed -out:mandelbrot-release;;
    *)
        $ODIN run . -define:CELL_SIZE=$CELL_SIZE -debug -out:mandelbrot-debug;;
esac
