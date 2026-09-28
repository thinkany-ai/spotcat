.PHONY: build run debug universal release icons clean

build:
	./scripts/bundle.sh release

debug:
	./scripts/bundle.sh debug

# 只重启本地构建的开发版，不影响已安装的正式版（两者可执行文件同名）
run: build
	-pkill -f "build/Spotcat.app/Contents/MacOS/Spotcat"
	@while pgrep -f "build/Spotcat.app/Contents/MacOS/Spotcat" >/dev/null; do sleep 0.1; done
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
