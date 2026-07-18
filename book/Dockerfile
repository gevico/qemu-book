FROM pandoc/latex@sha256:b913598b76b543c7ac09920a8ff5c824f7abee023f31d53d6b84e2f7343e732a

RUN apk add --no-cache \
        bash \
        font-noto-cjk \
        perl \
        ripgrep \
        texmf-dist-langchinese \
        texmf-dist-latexextra \
        texmf-dist-xetex

ENV TEXMFHOME=/usr/share/texmf-dist

WORKDIR /workspace/book
ENTRYPOINT []
