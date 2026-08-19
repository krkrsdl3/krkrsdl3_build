echo "[1/2] Configuring CMake..."
cmake --preset="Linux Config Console"
echo

echo "[2/2] Building Release version..."
cmake --build --preset="Linux Release Build Console"
echo
