NAME      := glider
DATASPACE := 11264  # >= ds_size in glider.asm (10624), plus stack slack
VASM      := C:/Users/tomco/app/vasm/vasmm68k_mot.exe
QEMU      := C:/Program Files (x86)/QemuLator/QemuLator 4/QemuLator.exe

all: $(NAME).qlpak

sin.inc: ../tools/gensin.py
	python ../tools/gensin.py > sin.inc

../lib/vfont.inc: ../tools/genfont.py
	python ../tools/genfont.py -o $@

meshes.inc: ../tools/genmesh.py
	python ../tools/genmesh.py --game > meshes.inc

sparks.inc: ../tools/gensparks.py
	python ../tools/gensparks.py > sparks.inc

crack.inc: ../tools/gencrack.py ../tools/genfont.py
	python ../tools/gencrack.py > crack.inc

levels.inc: ../tools/genlevel.py
	python ../tools/genlevel.py > levels.inc

# Every source here and in lib/, so a new include file needs no edit
# (a spare rebuild costs ~40 ms). The generated tables are named too:
# after a clean the wildcard can't see them, and they must be rebuilt.
SRCS := $(sort $(wildcard *.asm *.inc ../lib/*.asm) sin.inc meshes.inc sparks.inc \
        crack.inc levels.inc ../lib/vfont.inc)

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

# The beta for testers (spec 11.1): the .qlpak and the .mdv (medium
# STARQLIDER) under the game's name, with BETA.txt as README.txt, in
# release/ and zipped. Build with dev and every test_* flag at 0.
REL := starqlider
release: $(NAME).qlpak $(NAME)_bin boot BETA.txt ../tools/mkmdv.py
	pwsh -NoProfile -Command "New-Item -ItemType Directory -Force release | Out-Null; Copy-Item $(NAME).qlpak release/$(REL).qlpak; Copy-Item BETA.txt release/README.txt"
	python ../tools/mkmdv.py --name $(NAME) --dataspace $(DATASPACE) --label STARQLIDER --out release/$(REL).mdv
	python ../tools/mkmdv.py --verify release/$(REL).mdv
	pwsh -NoProfile -Command "Compress-Archive -Force -Path release/$(REL).qlpak,release/$(REL).mdv,release/README.txt -DestinationPath release/$(REL)-beta1.zip"

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
	pwsh -NoProfile -Command "Remove-Item $(NAME)_bin, $(NAME).lst, $(NAME).qlpak, $(NAME).mdv, qlshot.png, sin.inc, meshes.inc, sparks.inc, crack.inc, levels.inc -ErrorAction SilentlyContinue; Remove-Item stage, release -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all check mdv release run runmdv shot clean
