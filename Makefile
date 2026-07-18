SHELL := /bin/bash

BOOK_IMAGE ?= gevico/qemu-book-builder
DOCKER_PLATFORM ?= linux/amd64

.PHONY: help check-content check-experiments pdf pdf-native clean

help:
	@echo "Targets:"
	@echo "  make check-content  Check chapter length and experiment gates"
	@echo "  make check-experiments  Check experiment layout and manuals"
	@echo "  make pdf         Build the PDF in Docker (recommended)"
	@echo "  make pdf-native  Build with local pandoc and xelatex"
	@echo "  make clean       Remove generated PDF artifacts"

check-content:
	./book/check_content.sh --enforce

check-experiments:
	./experiments/tools/check-layout.sh

pdf:
	DOCKER_DEFAULT_PLATFORM=$(DOCKER_PLATFORM) docker build \
		--platform $(DOCKER_PLATFORM) \
		-t $(BOOK_IMAGE) \
		-f book/Dockerfile .
	docker run --rm \
		--platform $(DOCKER_PLATFORM) \
		-e BOOK_DATE="$${BOOK_DATE:-$$(date '+%Y-%m-%d')}" \
		-e BOOK_REPOSITORY_REF \
		-e BOOK_VERSION \
		-e OUTPUT_FILENAME \
		-v "$(CURDIR):/workspace" \
		-w /workspace/book \
		$(BOOK_IMAGE) ./build_pdf.sh

pdf-native:
	./book/build_pdf.sh

clean:
	rm -f output/pdf/*.pdf
