all: build docs test

test:
	@echo "Running all tests"
	nimble test

build:
	@echo "Building all binaries"
	nimble build

.PHONY: docs


docs: docs/theindex.html docs/pdf/abif.pdf docs/pdf/abi2fq.pdf docs/pdf/abimetadata.pdf docs/pdf/abichromatogram.pdf
	find src/htmldocs/ -type f | xargs rm -v
	echo "All documentation generated."

docs/theindex.html:
	nimble docs

docs/pdf/%.pdf: src/%.nim
	@echo "Generating documentation for $<"
	nim doc2tex $<
	nim doc2tex $<
	cd src/htmldocs/ && xelatex $(notdir $(basename $<)).tex && cd ../..
	mv -v src/htmldocs/$(notdir $(basename $<)).pdf docs/pdf/

docs: $(patsubst src/%.nim,docs/pdf/%.pdf,$(wildcard src/*.nim))

# Make clean should remove bin/* and all the binaries (not .nim!) in tests 
clean:
	find docs/ -name "*.idx" | xargs rm -v
	find docs/ -name "theindex.html" | xargs rm -v
	find . -name abif.log -delete
	find bin/  -type f  | xargs rm -v
	find tests -type f -name "test_*" ! -name '*.nim' | xargs rm -v
	find src/htmldocs docs/pdf/ -type f | xargs rm -v
