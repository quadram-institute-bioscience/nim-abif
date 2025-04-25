all:
	nimble build
	nimble test

# Make clean should remove bin/* and all the binaries (not .nim!) in tests
clean:
	rm -rf bin/*
	find tests -type f -name "test_*" ! -name '*.nim' -delete