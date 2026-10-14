# vendor/ (not part of this project)

The fallback Docker mode (`./install.sh --docker`) and the byte-for-byte test (`tools/verify.sh`) run
Ricoh's own Linux filter. It is Ricoh's software and is not distributed here. If you have Ricoh's
"SP-210211-series-Printer-0.03" Linux driver package, copy its `rastertolilo` filter here:

    vendor/rastertolilo   sha256 4d99ab2b66b674600d15bcea2dbb30da91f6bfd07dc8390f82f7dcefeb8465ab

The normal install (`./install.sh`) does not need it.
