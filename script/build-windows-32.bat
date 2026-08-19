@echo off

echo [1/2] Configuring CMake...
cmake --preset="Windows Config 32"
echo[

echo [2/2] Building Release version...
cmake --build --preset="Windows Release Build 32"
echo[