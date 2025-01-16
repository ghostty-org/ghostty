FROM docker.io/library/debian:12


RUN apt-get -y update
RUN apt-get -y install xz-utils libadwaita-1-0 libc6 libfontconfig1 libfreetype6 libgtk-4-1 libharfbuzz0b libonig5 libx11-6
ADD https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz /tmp/zig.tar.xz
RUN mkdir /zig; tar --extract --strip-components 1 --directory /zig --file /tmp/zig.tar.xz
ADD . /ghostty
RUN cd /ghostty; /zig/zig build  
