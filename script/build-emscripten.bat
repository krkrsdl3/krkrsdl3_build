@echo off

echo [1/2] Configuring CMake for Emscripten...
cmake --preset="Emscripten Config" -DUSE_FFMPEG=OFF
echo[

echo [2/2] Building Release version...
cmake --build --preset="Emscripten Release Build"
echo[