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
	"$(VASM)" -m68008 -Fbin -L $(NAME).lst -o $@ $(NAME).asm

check: $(NAME).asm
	$(REGCHECK) $(NAME).asm

$(NAME).qlpak: $(NAME)_bin boot $(NAME).QCF ../tools/mkqlpak.ps1
	pwsh -NoProfile -File ../tools/mkqlpak.ps1 -Name $(NAME) -DataSpace $(DATASPACE)

run: $(NAME).qlpak
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList '$(NAME).qlpak'"

# Look without a human (tools/qlshot.py): relaunch the package, wait
# SHOTWAIT seconds, write qlshot.png (the displayed screen), print the
# PEEK specs (labels from $(NAME).lst), close the emulator.
#   make shot PEEK="label:w label+4:l*2"
SHOTWAIT ?= 3
shot: $(NAME).qlpak
	python ../tools/qlshot.py run $(NAME).qlpak --wait $(SHOTWAIT) --close $(if $(PEEK),--peek $(PEEK))

clean:
	pwsh -NoProfile -Command "Remove-Item $(NAME)_bin, $(NAME).lst, $(NAME).qlpak, qlshot.png -ErrorAction SilentlyContinue; Remove-Item stage -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all check run shot clean
