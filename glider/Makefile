NAME      := glider
DATASPACE := 8704   # >= ds_size (zfar*4) in glider.asm, plus stack slack
VASM      := C:/Users/tomco/app/vasm/vasmm68k_mot.exe
QEMU      := C:/Program Files (x86)/QemuLator/QemuLator 4/QemuLator.exe

all: $(NAME).qlpak

sin.inc: ../tools/gensin.py
	python ../tools/gensin.py > sin.inc

meshes.inc: ../tools/genmesh.py
	python ../tools/genmesh.py --game > meshes.inc

# Every source here and in lib/, so a new include file needs no edit
# (a spare rebuild costs ~40 ms). The generated tables are named too:
# after a clean the wildcard can't see them, and they must be rebuilt.
SRCS := $(sort $(wildcard *.asm *.inc ../lib/*.asm) sin.inc meshes.inc)

# Register contracts (CLAUDE.md) are checked before every assembly; a
# problem stops the build. "make check" runs the check alone.
REGCHECK := python ../tools/regcheck.py -Dds_avail=$(DATASPACE)

$(NAME)_bin: $(SRCS) ../tools/regcheck.py
	$(REGCHECK) $(NAME).asm
	"$(VASM)" -m68008 -Fbin -Dds_avail=$(DATASPACE) -L $(NAME).lst -o $@ $(NAME).asm

check: $(SRCS)
	$(REGCHECK) $(NAME).asm

$(NAME).qlpak: $(NAME)_bin boot $(NAME).QCF ../tools/mkqlpak.ps1
	pwsh -NoProfile -File ../tools/mkqlpak.ps1 -Name $(NAME) -DataSpace $(DATASPACE)

mdv: $(NAME).mdv

$(NAME).mdv: $(NAME)_bin boot ../tools/mkmdv.py
	python ../tools/mkmdv.py --name $(NAME) --dataspace $(DATASPACE)

run: $(NAME).qlpak
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList '$(NAME).qlpak'"

runmdv: $(NAME).mdv
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList '$(NAME)_mdv.QCF'"

# Look without a human (tools/qlshot.py): relaunch the package, wait
# SHOTWAIT seconds, write qlshot.png (the displayed screen), print the
# PEEK specs (labels from $(NAME).lst), close the emulator.
#   make shot PEEK="headroom+12:w headroom+32:w*4"
SHOTWAIT ?= 3
shot: $(NAME).qlpak
	python ../tools/qlshot.py run $(NAME).qlpak --wait $(SHOTWAIT) --close $(if $(PEEK),--peek $(PEEK))

clean:
	pwsh -NoProfile -Command "Remove-Item $(NAME)_bin, $(NAME).lst, $(NAME).qlpak, $(NAME).mdv, qlshot.png, sin.inc, meshes.inc -ErrorAction SilentlyContinue; Remove-Item stage -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all check mdv run runmdv shot clean
