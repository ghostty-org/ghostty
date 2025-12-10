#--------------------------------------------------------------------
# Generate documentation with Doxygen
#--------------------------------------------------------------------
FROM --platform=linux/amd64 archlinux:latest AS builder

# Build argument for noindex header
ARG ADD_NOINDEX_HEADER=false
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    doxygen \
    graphviz && \
    pacman -Scc --noconfirm
WORKDIR /ghostty
COPY include/ ./include/
COPY images/ ./images/
COPY dist/doxygen/ ./dist/doxygen/
COPY example/ ./example/
COPY Doxyfile ./
COPY DoxygenLayout.xml ./
RUN mkdir -p zig-out/share/ghostty/doc/libghostty
RUN doxygen

#--------------------------------------------------------------------
# Host the static HTML
#--------------------------------------------------------------------
FROM nginx:alpine AS runtime

# Pass build arg to runtime stage
ARG ADD_NOINDEX_HEADER=false
ENV ADD_NOINDEX_HEADER=$ADD_NOINDEX_HEADER

# Copy documentation and entrypoint script
COPY --from=builder /ghostty/zig-out/share/ghostty/doc/libghostty /usr/share/nginx/html
COPY src/build/docker/lib-c-docs/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
CMD ["/entrypoint.sh"]
