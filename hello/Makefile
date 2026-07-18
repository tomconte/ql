VASM      := C:/Users/tomco/app/vasm/vasmm68k_mot.exe
QEMU      := C:/Program Files (x86)/QemuLator/QemuLator 4/QemuLator.exe
DATASPACE := 512

all: hello.qlpak

hello_bin: hello.asm
	"$(VASM)" -m68008 -Fbin -o $@ $<

hello.qlpak: hello_bin boot hello.QCF mkqlpak.ps1
	pwsh -NoProfile -File mkqlpak.ps1 -DataSpace $(DATASPACE)

run: hello.qlpak
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList 'hello.qlpak'"

clean:
	pwsh -NoProfile -Command "Remove-Item hello_bin, hello.qlpak -ErrorAction SilentlyContinue; Remove-Item stage -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all run clean
