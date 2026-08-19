echo "[1/2] Configuring CMake..."
cmake --preset="Linux Config"
echo

echo "[2/2] Building Release version..."
cmake --build --preset="Linux Release Build"
echo
