<!-- markdownlint-configure-file { "MD004": { "style": "consistent" } } -->
<!-- markdownlint-disable MD033 -->
#

<p align="center">
    <a href="https://pi-hole.net/#gh-light-mode-only">
        <img src="https://github.com/pi-hole/graphics/blob/master/Vortex/Vortex_Vertical_wordmark_lightmode.png?raw=true)" alt="Pi-hole">
    </a>
        <a href="https://pi-hole.net/#gh-dark-mode-only">
        <img src="https://github.com/pi-hole/graphics/blob/master/Vortex/Vortex_Vertical_wordmark_darkmode.png?raw=true" alt="Pi-hole">
    </a>
    <br>
    <strong>Network-wide ad blocking via your own Linux hardware</strong>
</p>
<!-- markdownlint-enable MD033 -->

The Pi-hole® is a [DNS sinkhole](https://en.wikipedia.org/wiki/DNS_Sinkhole) that protects your devices from unwanted content without installing any client-side software.

  **Alpine version: x86, x86_64, armv7l and aarch64**: This repository provides an automated script to install Pi-hole on Alpine Linux (32-bit and 64-bit) working with musl.
   The 32-bit version for Alpine compiles the [Faster-than-light Engine](https://github.com/pi-hole/ftl).
   More information is available at its own [repository](https://gitlab.com/yvelon/pihole-FTL-alpine).

   **Information about Pi-hole**: please check out the [Pi-hole official repository](https://github.com/pi-hole/pi-hole).

-----
## Important note

This script runs the Docker part of the awesome script of [Yvelon's pihole project](https://gitlab.com/yvelon/pi-hole).
All cudos to him and his awesome work. Thank you for helping me port your work into docker.



## How to run
Simply run docker build -t my-tag . in the project directory.
