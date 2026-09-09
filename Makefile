BINARY = TouchBarAgentStatus
AGENT_ID = com.riotsakura.touchbar.opencode-status
AGENT_PLIST = $(HOME)/Library/LaunchAgents/$(AGENT_ID).plist
# 二进制安装位置: ~/Documents 受 TCC 保护, launchd 启动的进程打开会被阻塞
APP_DIR = $(HOME)/Library/Application Support/TouchBarAgentStatus
APP_BIN = $(APP_DIR)/$(BINARY)

.PHONY: build run once install-agent uninstall-agent clean

build:
	swiftc -O -swift-version 5 main.swift -o $(BINARY)

run: build
	./$(BINARY)

once: build
	./$(BINARY) --once

install-agent: build
	@mkdir -p "$(APP_DIR)"
	@cp $(BINARY) "$(APP_BIN)"
	@mkdir -p $(HOME)/Library/LaunchAgents
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n\t<key>Label</key>\n\t<string>$(AGENT_ID)</string>\n\t<key>ProgramArguments</key>\n\t<array>\n\t\t<string>$(APP_BIN)</string>\n\t</array>\n\t<key>RunAtLoad</key>\n\t<true/>\n\t<key>KeepAlive</key>\n\t<true/>\n</dict>\n</plist>\n' > $(AGENT_PLIST)
	launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	launchctl load $(AGENT_PLIST)
	@echo "LaunchAgent 已安装并启动: $(AGENT_PLIST)"

uninstall-agent:
	launchctl unload $(AGENT_PLIST) 2>/dev/null || true
	rm -f $(AGENT_PLIST)
	pkill -f $(BINARY) 2>/dev/null || true
	@echo "已卸载"

clean:
	rm -f $(BINARY)
