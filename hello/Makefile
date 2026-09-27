NAME      := hello
DATASPACE := 512
VASM      := C:/Users/tomco/app/vasm/vasmm68k_mot.exe
QEMU      := C:/Program Files (x86)/QemuLator/QemuLator 4/QemuLator.exe

all: $(NAME).qlpak

# Register contracts (CLAUDE.md) are checked before every assembly; a
# problem stops the build. "make check" runs the check alone.
REGCHECK := python ../tools/regcheck.py

$(NAME)_bin: $(NAME).asm ../tools/regcheck.py
	$(REGCHECK) $(NAME).asm
	"$(VASM)" -m68008 -Fbin -o $@ $(NAME).asm

check: $(NAME).asm
	$(REGCHECK) $(NAME).asm

$(NAME).qlpak: $(NAME)_bin boot $(NAME).QCF ../tools/mkqlpak.ps1
	pwsh -NoProfile -File ../tools/mkqlpak.ps1 -Name $(NAME) -DataSpace $(DATASPACE)

run: $(NAME).qlpak
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList '$(NAME).qlpak'"

clean:
	pwsh -NoProfile -Command "Remove-Item $(NAME)_bin, $(NAME).qlpak -ErrorAction SilentlyContinue; Remove-Item stage -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all check run clean
