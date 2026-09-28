.PHONY: build run debug universal release icons clean

build:
	./scripts/bundle.sh release

debug:
	./scripts/bundle.sh debug

run: build
	-pkill -x Spotcat
	@while pgrep -x Spotcat >/dev/null; do sleep 0.1; done
	open build/Spotcat.app

universal:
	./scripts/bundle.sh release --universal

# 签名 + 公证 + DMG/ZIP（需要 APPLE_* 环境变量，见 scripts/release.sh）
release:
	./scripts/release.sh

icons:
	./scripts/make-icons.sh

clean:
	rm -rf .build build dist
