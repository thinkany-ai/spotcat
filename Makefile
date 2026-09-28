.PHONY: build run debug universal release icons clean

build:
	./scripts/bundle.sh release

debug:
	./scripts/bundle.sh debug

# 构建并重启开发版 build/Spotcat Dev.app，不影响已安装的正式版
run: build
	-pkill -f "build/Spotcat Dev.app/Contents/MacOS/Spotcat"
	@while pgrep -f "build/Spotcat Dev.app/Contents/MacOS/Spotcat" >/dev/null; do sleep 0.1; done
	open "build/Spotcat Dev.app"

universal:
	./scripts/bundle.sh release --universal

# 签名 + 公证 + DMG/ZIP（需要 APPLE_* 环境变量，见 scripts/release.sh）
release:
	./scripts/release.sh

icons:
	./scripts/make-icons.sh

clean:
	rm -rf .build build dist
