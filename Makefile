CC=clang
nanoasm: nanoasm.cc
	clang++ -std=c++11 -Wno-deprecated-register -o nanoasm nanoasm.cc

nanoasm.cc: nanoasm.l
	flex -o nanoasm.cc nanoasm.l

test: nanoasm
	./nanoasm  test.a
