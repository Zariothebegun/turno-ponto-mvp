# Local QR libraries

The production page loads these browser libraries from this directory so QR generation and camera scanning do not depend on third-party CDN availability at runtime.

- `qrcode.min.js`: QRCode.js by davidshimjs, MIT license; source: https://github.com/davidshimjs/qrcodejs
- `html5-qrcode.min.js`: html5-qrcode v2.3.8 by Mehul Kabaria, Apache-2.0 license; source: https://github.com/mebjas/html5-qrcode

License texts are included alongside each library. Scanner camera access requires HTTPS and browser permission.