@echo off

echo [1/2] Configuring CMake...
cmake --preset="Windows Config MSVC"
echo[

echo [2/2] Building Release version...
cmake --build --preset="Windows Release Build MSVC"
echo[