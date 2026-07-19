NAME      := game8
DATASPACE := 512
VASM      := C:/Users/tomco/app/vasm/vasmm68k_mot.exe
QEMU      := C:/Program Files (x86)/QemuLator/QemuLator 4/QemuLator.exe

all: $(NAME).qlpak

$(NAME)_bin: $(NAME).asm ../lib/ipc_sound_takeover.asm ../lib/ipc_keys_takeover.asm
	"$(VASM)" -m68008 -Fbin -o $@ $(NAME).asm

$(NAME).qlpak: $(NAME)_bin boot $(NAME).QCF ../tools/mkqlpak.ps1
	pwsh -NoProfile -File ../tools/mkqlpak.ps1 -Name $(NAME) -DataSpace $(DATASPACE)

run: $(NAME).qlpak
	pwsh -NoProfile -Command "Start-Process -FilePath '$(QEMU)' -ArgumentList '$(NAME).qlpak'"

clean:
	pwsh -NoProfile -Command "Remove-Item $(NAME)_bin, $(NAME).qlpak -ErrorAction SilentlyContinue; Remove-Item stage -Recurse -Force -ErrorAction SilentlyContinue"

.PHONY: all run clean
