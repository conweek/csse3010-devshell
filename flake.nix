{
  description = "CSSE3010 cross-platform dev shell (macOS + Linux)";

  inputs = {
    # Pin to the same stable release as the WSL image so every
    # student gets byte-identical ARM toolchain versions.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
  };

  outputs = { self, nixpkgs, ... }:
  let
    # Systems we support
    supportedSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];

    forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems (system: f system);
  in
  {
    devShells = forAllSystems (system:
    let
      pkgs = import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          segger-jlink.acceptLicense = true;
          allowInsecurePredicate = pkg:
            nixpkgs.lib.hasPrefix "segger-jlink" (nixpkgs.lib.getName pkg);
        };
      };

      isLinux  = pkgs.stdenv.isLinux;
      isDarwin = pkgs.stdenv.isDarwin;

      # ── Helper: art file baked into the store ──────────────────────
      motdArtFile = ./art;

      # ── Scripts (identical to the WSL image) ───────────────────────

      motdScript = pkgs.writeShellScriptBin "motd" ''
        ART_FILE="${motdArtFile}"
        if [ ! -f "$ART_FILE" ]; then
          exit 0
        fi

        mapfile -t lines < "$ART_FILE"

        blocks=()
        current=""
        for line in "''${lines[@]}"; do
          if [ -z "$line" ]; then
            if [ -n "$current" ]; then
              blocks+=("$current")
              current=""
            fi
          else
            if [ -n "$current" ]; then
              current="''${current}"$'\n'"''${line}"
            else
              current="$line"
            fi
          fi
        done
        if [ -n "$current" ]; then
          blocks+=("$current")
        fi

        num_blocks=''${#blocks[@]}
        if [ "$num_blocks" -eq 0 ]; then
          exit 0
        fi

        index=$((RANDOM % num_blocks))
        art="''${blocks[$index]}"

        colours=(31 32 33 34 35 36 91 92 93 94 95 96)
        num_colours=''${#colours[@]}
        colour_index=$((RANDOM % num_colours))
        colour="''${colours[$colour_index]}"

        printf '\e[%sm%s\e[0m\n' "$colour" "$art"
      '';

      configureInfoScript = pkgs.writeShellScriptBin "configure-info" ''
        set -euo pipefail

        if [ $# -ge 2 ]; then
          STUDENT_ID="$1"
          shift
          FULL_NAME="$*"
        else
          read -rp "Enter your 8 digit UQ student number (e.g. 48201356): " STUDENT_ID
          read -rp "Enter your full name: " FULL_NAME
        fi

        if [[ ! "$STUDENT_ID" =~ ^[0-9]{8}$ ]]; then
          echo "Error: Invalid format. Must be 8 digits (e.g. 48201356)."
          exit 1
        fi

        if [ -z "$FULL_NAME" ]; then
          echo "Error: Full name cannot be empty."
          exit 1
        fi
        UQ_USERNAME="s''${STUDENT_ID:0:7}"
        EMAIL="$UQ_USERNAME@student.uq.edu.au"

        GITCFG="''${GIT_CONFIG_GLOBAL:-$HOME/.config/csse3010/gitconfig}"
        mkdir -p "$(dirname "$GITCFG")"
        ${pkgs.git}/bin/git config --file "$GITCFG" user.name "$FULL_NAME"
        ${pkgs.git}/bin/git config --file "$GITCFG" user.email "$EMAIL"

        echo "Git configured (in $GITCFG):"
        echo "  user.name  = $FULL_NAME"
        echo "  user.email = $EMAIL"
      '';

      # Background script: generate SSH key (runs in shellHook, mirrors WSL systemd oneshot)
      generateSshKeysScript = pkgs.writeShellScript "csse3010-generate-ssh-keys" ''
        set -euo pipefail
        KEY="$HOME/.ssh/id_ed25519"
        if [ -f "$KEY" ]; then
          exit 0
        fi
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ${pkgs.openssh}/bin/ssh-keygen -t ed25519 \
          -f "$KEY" \
          -N "" \
          -C "$(whoami)@csse3010"
        chmod 600 "$KEY"
        chmod 644 "$KEY.pub"
      '';

      # Background script: clone sourcelib (runs in shellHook, mirrors WSL systemd oneshot)
      setupSourcelibScript = pkgs.writeShellScript "csse3010-setup-sourcelib" ''
        set -euo pipefail
        if [ -d "$HOME/csse3010/sourcelib/.git" ]; then
          exit 0
        fi

        mkdir -p "$HOME/csse3010"

        MAX_RETRIES=10
        for i in $(seq 1 $MAX_RETRIES); do
          if ${pkgs.git}/bin/git clone \
               https://github.com/uqembeddedsys/sourcelib.git \
               "$HOME/csse3010/sourcelib"; then
            break
          fi
          echo "Clone attempt $i/$MAX_RETRIES failed, retrying in 5s..."
          sleep 5
        done
      '';

      firstTimeSetupScript = pkgs.writeShellScriptBin "csse3010-first-setup" ''
        set -euo pipefail

        # Already completed if SSH config has the lichen entry (written at end of setup)
        if grep -q "lichen" "$HOME/.ssh/config" 2>/dev/null; then
          echo "First-time setup already completed. To reconfigure git, use: configure-info"
          exit 0
        fi

        # Wait for background services (SSH key + sourcelib clone)
        if [ ! -f "$HOME/.ssh/id_ed25519" ] || [ ! -d "$HOME/csse3010/sourcelib/.git" ]; then
          printf "Waiting for first-boot services to complete..."
          _timeout=120
          _elapsed=0
          while [ ! -f "$HOME/.ssh/id_ed25519" ] || [ ! -d "$HOME/csse3010/sourcelib/.git" ]; do
            if [ "$_elapsed" -ge "$_timeout" ]; then
              echo ""
              echo "Timed out waiting for background setup. Please exit and re-enter the shell."
              exit 1
            fi
            printf "."
            sleep 2
            _elapsed=$((_elapsed + 2))
          done
          echo ""
        fi

        echo ""
        echo "======================================"
        echo "   CSSE3010 First-Time User Setup"
        echo "======================================"
        echo ""

        while true; do
          read -rp "Enter your 8 digit UQ student number (e.g. 48201356): " STUDENT_ID
          if [[ "$STUDENT_ID" =~ ^[0-9]{8}$ ]]; then
            break
          fi
          echo "Invalid format. Must be 8 digits (e.g. 48201356)."
        done
        UQ_USERNAME="s''${STUDENT_ID:0:7}"

        while true; do
          read -rp "Enter your full name: " FULL_NAME
          if [ -n "$FULL_NAME" ]; then
            break
          fi
          echo "Name cannot be empty."
        done

        EMAIL="$UQ_USERNAME@student.uq.edu.au"

        GITCFG="''${GIT_CONFIG_GLOBAL:-$HOME/.config/csse3010/gitconfig}"
        mkdir -p "$(dirname "$GITCFG")"
        ${pkgs.git}/bin/git config --file "$GITCFG" user.name "$FULL_NAME"
        ${pkgs.git}/bin/git config --file "$GITCFG" user.email "$EMAIL"
        echo ""
        echo "Git configured: $FULL_NAME <$EMAIL>"

        # Make sure students can't Ctrl+C out of the script when trying to copy text
        # TODO: UNCOMMENT THIS
        # trap "" INT

        echo ""
        echo "Your SSH public key:"
        echo "------------------------------------------------------------"
        cat "$HOME/.ssh/id_ed25519.pub"
        echo "------------------------------------------------------------"
        echo ""
        echo "Please add this key to the UQ EAIT and Gitea SSH key portals!"
        echo "Links: "
        printf "  \e[1mstudent.eait.uq.edu.au/accounts/sshkeys.ephp\n"
        printf "  csse3010-gitea.uqcloud.net/user/settings/keys\e[0m\n"
        printf "\e[1mUse Ctrl+Shift+C (Linux) or Cmd+C (macOS) to copy text.\e[0m\n"
        read -rp "Press Enter once you've added your key..."

        # Write SSH config
        cat > "$HOME/.ssh/config" << SSHEOF
Host lichen
    Hostname lichen.labs.eait.uq.edu.au
    User $UQ_USERNAME
    IdentityFile $HOME/.ssh/id_ed25519
    ForwardAgent yes

Host csse3010-gitea.zones.eait.uq.edu.au
    Hostname csse3010-gitea.zones.eait.uq.edu.au
    IdentityFile $HOME/.ssh/id_ed25519
    ProxyJump lichen
SSHEOF
        chmod 600 "$HOME/.ssh/config"
        printf "\e[32mSSH config written to ~/.ssh/config\e[0m\n"

        # Test SSH connection to lichen (retry until key is accepted)
        while true; do
          echo ""
          echo "Testing SSH connection to lichen..."
          if ${pkgs.openssh}/bin/ssh -i "$HOME/.ssh/id_ed25519" -o PasswordAuthentication=no -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$UQ_USERNAME@lichen.labs.eait.uq.edu.au" true &>/dev/null; then
            printf "\e[32mSSH connection to lichen successful!\e[0m\n"
            break
          fi
          echo ""
          printf "\e[31m\e[1mSSH connection to lichen failed.\e[0m\n"
          echo "Please ensure your public key is added to the EAIT SSH key portal."
          echo ""
          echo "Your SSH public key:"
          echo "------------------------------------------------------------"
          cat "$HOME/.ssh/id_ed25519.pub"
          echo "------------------------------------------------------------"
          echo ""
          echo "Please copy this key into the portal located at:"
          printf "  \e[1mhttps://student.eait.uq.edu.au/accounts/sshkeys.ephp\e[0m\n"
          read -rp "Press Enter to retry..."
        done

        # Clone student repo (retry until gitea key is accepted)
        REPO_URL="git@csse3010-gitea.zones.eait.uq.edu.au:$STUDENT_ID/repo.git"
        if [ -d "$HOME/csse3010/repo/.git" ]; then
          echo "Repo already cloned to ~/csse3010/repo, skipping."
        else
          rm -rf "$HOME/csse3010/repo"
          while true; do
            echo ""
            echo "Cloning your CSSE3010 repo..."
            if GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=accept-new" \
               ${pkgs.git}/bin/git clone "$REPO_URL" "$HOME/csse3010/repo" &>/dev/null; then
              printf "\e[32m\e[1mRepo cloned successfully to ~/csse3010/repo!\e[0m\n"
              break
            fi
            echo ""
            printf "\e[31m\e[1mClone failed. Please ensure your SSH key is also added to the CSSE3010 Gitea portal.\e[0m"
            echo ""
            echo "Your SSH public key:"
            echo "------------------------------------------------------------"
            cat "$HOME/.ssh/id_ed25519.pub"
            echo "------------------------------------------------------------"
            echo ""
            echo "Please add this key into your Gitea SSH Key portal at:"
            printf "  \e[1mcsse3010-gitea.uqcloud.net/user/settings/keys\e[0m\n"
            read -rp "Press Enter to retry..."
          done
        fi

        # Install udev rules and add user to device groups (Linux only)
        if [ "$(uname)" = "Linux" ]; then
          echo ""
          echo "Setting up device permissions (requires sudo)..."
          sudo tee /etc/udev/rules.d/99-csse3010.rules > /dev/null << 'RULESEOF'
# Generic serial (ttyACM*, ttyUSB*)
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout"

# SEGGER J-Link
SUBSYSTEM=="usb", ATTR{idVendor}=="1366", MODE="0666", GROUP="plugdev"

# ST-Link v2 and v2.1
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="3748", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="374b", MODE="0666", GROUP="plugdev"
RULESEOF
          sudo udevadm control --reload-rules
          sudo udevadm trigger
          sudo usermod -aG dialout,plugdev "$(whoami)"
          printf '\e[32mDevice permissions configured!\e[0m\n'
          echo "Note: You may need to log out and back in for group changes to take effect."
        fi

        clear

        printf "\e[32m\e[1m"
        echo "======================================"
        echo " Setup complete! Welcome to CSSE3010! "
        echo "======================================"
        printf "\e[0m"
        sleep 2
      '';

      jlinkDebuggerScript = pkgs.writeShellScriptBin "debug" ''
        (
          # Create temp log
          LOG=$(mktemp);

          # Start the JLinkGDBServer, routing the output to the logfile
          JLinkGDBServerCL -device STM32F429ZI -if SWD -speed 4000 -port 2331 -swoport 2332 -telnetport 2333 >"$LOG" 2>&1 & PID=$!;

          # Make sure the server has actually started
          grep -q "Listening on TCP/IP port 2331" <(tail -f "$LOG");

          # Run GDB
          if [ "$#" -ge 1 ]; then
            arm-none-eabi-gdb "$1" -ex "target remote localhost:2331" -ex "monitor reset halt" -ex "load";
          else
            arm-none-eabi-gdb main.elf -ex "target remote localhost:2331" -ex "monitor reset halt" -ex "load";
          fi

          # Kill the JLinkGDBServer if GDB exits
          kill $PID;

          # Remove the log file
          rm "$LOG";
        )
      '';

      # VS Code workspace configuration files
      vscodeTasksJson = pkgs.writeText "vscode-tasks.json" ''
        {
            "version": "2.0.0",
            "tasks": [
                {
                    "label": "make",
                    "type": "shell",
                    "command": "make"
                },
                {
                    "label": "flash",
                    "type": "shell",
                    "dependsOn": "make",
                    "command": "make flash",
                    "group": {
                        "kind": "build",
                        "isDefault": true
                    }
                },
                {
                    "label": "clean",
                    "type": "shell",
                    "command": "make clean"
                }
            ]
        }
      '';

      vscodeLaunchJson = pkgs.writeText "vscode-launch.json" ''
        {
            "configurations": [
                {
                    "name": "Debug",
                    "cwd": "''${workspaceRoot}",
                    "executable": "''${workspaceRoot}/main.elf",
                    "preLaunchTask": "make",
                    "request": "launch",
                    "type": "cortex-debug",
                    "servertype": "jlink",
                    "device": "STM32F429ZI",
                    "interface": "swd",
                    "runToEntryPoint": "main",
                    "rtos": "FreeRTOS",
                    "svdFile": "''${userHome}/csse3010/sourcelib/tools/vscode/STM32F429.svd"
                }
            ]
        }
      '';

      vscodeSettingsJson = pkgs.writeText "vscode-settings.json" ''
        {
            // Reroute JLinkGDBServer to JLinkGDBServerCL
            "cortex-debug.JLinkGDBServerPath.linux": "JLinkGDBServerCL",

            "editor.rulers": [79],
            "editor.renderWhitespace": "all",
            "editor.tabSize": 4,
            "editor.insertSpaces": true
        }
      '';

      vscodeCCppPropertiesJson = pkgs.writeText "vscode-c_cpp_properties.json" ''
        {
            "configurations": [
                {
                    "name": "CSSE3010 Repo",
                    "includePath": [
                        "''${workspaceFolder}/**",
                        "../mylib/**",
                        "''${userHome}/csse3010/sourcelib/components/boards/nucleo-f429zi/Inc/**",
                        "''${userHome}/csse3010/sourcelib/components/hal/STM32F4xx_HAL_Driver/Inc/**",
                        "''${userHome}/csse3010/sourcelib/components/hal/CMSIS/Include/**",
                        "''${userHome}/csse3010/sourcelib/components/os/FreeRTOS/include/**",
                        "''${userHome}/csse3010/sourcelib/components/os/FreeRTOS/portable/GCC/ARM_CM4F"
                    ],
            "cStandard": "c99",
        "intelliSenseMode": "gcc-arm",
                    "defines": [
                        "STM32F429xx",
                        "__INT8_TYPE__=signed char",
                        "__INT16_TYPE__=signed short int",
                        "__INT32_TYPE__=signed long int",
                        "__INT64_TYPE__=signed long long int",
                        "__UINT8_TYPE__=unsigned char",
                        "__UINT16_TYPE__=unsigned short int",
                        "__UINT32_TYPE__=unsigned long int",
                        "__UINT64_TYPE__=unsigned long long int",
                        "__INT_LEAST8_TYPE__=signed char",
                        "__INT_LEAST16_TYPE__=signed short int",
                        "__INT_LEAST32_TYPE__=signed long int",
                        "__INT_LEAST64_TYPE__=signed long long int",
                        "__UINT_LEAST8_TYPE__=unsigned char",
                        "__UINT_LEAST16_TYPE__=unsigned short int",
                        "__UINT_LEAST32_TYPE__=unsigned long int",
                        "__UINT_LEAST64_TYPE__=unsigned long long int",
                        "__INT_FAST8_TYPE__=signed char",
                        "__INT_FAST16_TYPE__=signed short int",
                        "__INT_FAST32_TYPE__=signed long int",
                        "__INT_FAST64_TYPE__=signed long long int",
                        "__UINT_FAST8_TYPE__=unsigned char",
                        "__UINT_FAST16_TYPE__=unsigned short int",
                        "__UINT_FAST32_TYPE__=unsigned long int",
                        "__UINT_FAST64_TYPE__=unsigned long long int",
                        "__INTPTR_TYPE__=signed int",
                        "__UINTPTR_TYPE__=unsigned int",
                        "__INTMAX_TYPE__=signed long long int",
                        "__UINTMAX_TYPE__=unsigned long long int",
                        "__INT8_MAX__=127",
                        "__UINT8_MAX__=255",
                        "__INT16_MAX__=32767",
                        "__UINT16_MAX__=65535",
                        "__INT32_MAX__=2147483647L",
                        "__UINT32_MAX__=4294967295UL",
                        "__INT64_MAX__=9223372036854775807LL",
                        "__UINT64_MAX__=18446744073709551615ULL",
                        "__INT_LEAST8_MAX__=127",
                        "__UINT_LEAST8_MAX__=255",
                        "__INT_LEAST16_MAX__=32767",
                        "__UINT_LEAST16_MAX__=65535",
                        "__INT_LEAST32_MAX__=2147483647L",
                        "__UINT_LEAST32_MAX__=4294967295UL",
                        "__INT_LEAST64_MAX__=9223372036854775807LL",
                        "__UINT_LEAST64_MAX__=18446744073709551615ULL",
                        "__INT_FAST8_MAX__=127",
                        "__UINT_FAST8_MAX__=255",
                        "__INT_FAST16_MAX__=32767",
                        "__UINT_FAST16_MAX__=65535",
                        "__INT_FAST32_MAX__=2147483647L",
                        "__UINT_FAST32_MAX__=4294967295UL",
                        "__INT_FAST64_MAX__=9223372036854775807LL",
                        "__UINT_FAST64_MAX__=18446744073709551615ULL",
                        "__INTPTR_MAX__=2147483647L",
                        "__UINTPTR_MAX__=4294967295UL",
                        "__INTMAX_MAX__=9223372036854775807LL",
                        "__UINTMAX_MAX__=18446744073709551615ULL",
                        "__INT8_C(c)=c",
                        "__UINT8_C(c)=c",
                        "__INT16_C(c)=c",
                        "__UINT16_C(c)=c",
                        "__INT32_C(c)=c##L",
                        "__UINT32_C(c)=c##UL",
                        "__INT64_C(c)=c##LL",
                        "__UINT64_C(c)=c##ULL",
                        "__INTMAX_C(c)=c##LL",
                        "__UINTMAX_C(c)=c##ULL"
                    ]
                }
            ],
            "version": 4
        }
      '';

      clangdFile = pkgs.writeText "clangdFile" ''
        CompileFlags:
          Compiler: arm-none-eabi-gcc

          Add:
            - -I/usr/include/newlib
            - -I${pkgs.gcc-arm-embedded}/arm-none-eabi/include
            - -DUSE_FREERTOS_SYSTICK
            - -I$HOME/csse3010/sourcelib/components/os/FreeRTOS/include
            - -I$HOME/csse3010/sourcelib/components/os/FreeRTOS/portable/GCC/ARM_CM4F
            - -I$HOME/csse3010/sourcelib/components/os/FreeRTOS-Plus/Source/FreeRTOS-Plus-CLI
            - -DENABLE_DEBUG_UART
            - -Wmaybe-uninitialized
            - -Wextra
            - -std=gnu99
            - -Wsign-compare
            - -mlittle-endian
            - -mthumb
            - -mcpu=cortex-m4
            - -I$HOME/csse3010/sourcelib/components/hal/stm32/STM32_USB_Device_Library/Core/Inc
            - -I$HOME/csse3010/sourcelib/components/hal/stm32/STM32_USB_Device_Library/Class/CDC/Inc
            - -I$HOME/csse3010/sourcelib/components/boards/nucleo-f429zi/usb/vcp
            - -I$HOME/csse3010/sourcelib/components/boards/nucleo-f429zi/usb/hid
            - -I$HOME/csse3010/sourcelib/components/boards/nucleo-f429zi/usb
            - -I.
            - -I$HOME/csse3010/sourcelib/components/hal/stm32/STM32_USB_Device_Library/Class/HID/Inc
            - -I$HOME/csse3010/sourcelib/components/hal/CMSIS/Include
            - -I$HOME/csse3010/sourcelib/components/boards/nucleo-f429zi/Inc
            - -I$HOME/csse3010/sourcelib/components/hal/STM32F4xx_HAL_Driver/Inc
            - -I$HOME/csse3010/sourcelib/components/util
            - -DSTM32F429xx
            - -I$HOME/csse3010/repo/mylib
            - -I$HOME/csse3010/sourcelib/components/peripherals/nrf24l01plus

          Remove:
            - -mthumb-interwork
      '';

      vscodeSetupScript = pkgs.writeShellScriptBin "vscode-init" ''
        set -euo pipefail

        if [ $# -eq 0 ]; then
          set -- "."
        fi

        for dir in "$@"; do
          if [ ! -d "$dir" ]; then
            echo "Skipping '$dir': not a directory"
            continue
          fi

          VSCODE_DIR="$dir/.vscode"
          mkdir -p "$VSCODE_DIR"

          cp ${vscodeTasksJson} "$VSCODE_DIR/tasks.json"
          cp ${vscodeLaunchJson} "$VSCODE_DIR/launch.json"
          cp ${vscodeSettingsJson} "$VSCODE_DIR/settings.json"
          cp ${vscodeCCppPropertiesJson} "$VSCODE_DIR/c_cpp_properties.json"

          printf '\e[32mCreated .vscode config in %s\e[0m\n' "$(realpath "$dir")"
        done
      '';

      # Wrapper that shadows /usr/bin/sudo so Nix store paths are preserved
      # Works in make recipes, scripts, and interactive shells
      sudoWrapper = pkgs.writeShellScriptBin "sudo" ''
        exec /usr/bin/sudo env PATH="$PATH" LD_LIBRARY_PATH="''${LD_LIBRARY_PATH:-}" "$@"
      '';

      setupVscodeScript = pkgs.writeShellScriptBin "setup-vscode" ''
        set -euo pipefail

        if ! command -v code &>/dev/null; then
          echo "Error: VS Code is not installed or 'code' is not in your PATH."
          echo "Please install VS Code from https://code.visualstudio.com/"
          exit 1
        fi

        echo "Installing VS Code extensions..."
        code --install-extension marus25.cortex-debug
        code --install-extension ms-vscode.cpptools
        code --install-extension mcu-debug.debug-tracker-vscode
        code --install-extension mcu-debug.memory-view
        code --install-extension mcu-debug.peripheral-viewer
        code --install-extension mcu-debug.rtos-views
        printf '\e[32mVS Code extensions installed!\e[0m\n'
      '';

      clangdInit = pkgs.writeShellScriptBin "clangd-init" ''
        set -euo pipefail
        cp ${clangdFile} "$HOME/csse3010/.clangd"
        echo "Wrote .clangd to ~/csse3010/.clangd"
      '';

      updateScript = pkgs.writeShellScriptBin "update" ''
        set -euo pipefail
        printf '\e[33mUpdating sourcelib library...\e[0m\n'
        ${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" pull
        echo ""
        printf '\e[33mTo update the dev environment, run:\e[0m\n'
        echo "  nix flake update"
        echo "  then re-enter with: nix develop"
      '';

      # Helper script to install udev rules (Linux only)
      installUdevRulesScript = pkgs.writeShellScriptBin "install-udev-rules" ''
        set -euo pipefail
        if [ "$(uname)" != "Linux" ]; then
          echo "udev rules are only needed on Linux."
          exit 0
        fi

        RULES_FILE="/etc/udev/rules.d/99-csse3010.rules"
        echo "Writing udev rules to $RULES_FILE (requires sudo)..."

        sudo tee "$RULES_FILE" > /dev/null << 'RULESEOF'
# Generic serial (ttyACM*, ttyUSB*)
SUBSYSTEM=="tty", KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout"
SUBSYSTEM=="tty", KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout"

# SEGGER J-Link
SUBSYSTEM=="usb", ATTR{idVendor}=="1366", MODE="0666", GROUP="plugdev"

# ST-Link v2 and v2.1
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="3748", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="374b", MODE="0666", GROUP="plugdev"
RULESEOF

        sudo udevadm control --reload-rules
        sudo udevadm trigger
        printf '\e[32mudev rules installed and reloaded.\e[0m\n'
        echo ""
        echo "Make sure your user is in the 'dialout' and 'plugdev' groups:"
        echo "  sudo usermod -aG dialout,plugdev \$USER"
        echo "Then log out and back in for the group change to take effect."
      '';

      # ── VS Code with extensions (NixOS only) ─────────────────────
      vscode = pkgs.vscode-with-extensions.override {
        vscodeExtensions = with pkgs.vscode-extensions; [
          marus25.cortex-debug
          ms-vscode.cpptools
        ] ++ pkgs.vscode-utils.extensionsFromVscodeMarketplace [
          {
            name = "debug-tracker-vscode";
            publisher = "mcu-debug";
            version = "0.0.15";
            sha256 = "sha256-2u4Moixrf94vDLBQzz57dToLbqzz7OenQL6G9BMCn3I=";
          }
          {
            name = "memory-view";
            publisher = "mcu-debug";
            version = "0.0.25";
            sha256 = "sha256-Tck3MYKHJloiXChY/GbFvpBgLBzu6yFfcBd6VTpdDkc=";
          }
          {
            name = "peripheral-viewer";
            publisher = "mcu-debug";
            version = "1.4.6";
            sha256 = "sha256-flWBK+ugrbgy5pEDmGQeUzk1s2sCMQJRgrS3Ku1Oiag=";
          }
          {
            name = "rtos-views";
            publisher = "mcu-debug";
            version = "0.0.15";
            sha256 = "sha256-yytAP5U7urgKLcQO0rp6jlcxIVzDls6jWddaojTV6nQ=";
          }
        ];
      };

      # ── Platform-conditional packages ──────────────────────────────

      # segger-jlink is only available for Linux in nixpkgs
      linuxOnlyPackages = pkgs.lib.optionals isLinux [
        pkgs.segger-jlink
        pkgs.usbutils
        (pkgs.python3.withPackages (ps: [ ps.pylink-square ]))
        installUdevRulesScript
      ];

      # ── Common packages ──────────────────

      commonPackages = [
        pkgs.screen
        pkgs.gcc-arm-embedded
        pkgs.git
        pkgs.vim
        pkgs.neovim
        pkgs.gnumake
        pkgs.openssh
        pkgs.wget
        pkgs.curl
        pkgs.minicom

        # LSP
        pkgs.clang-tools
        pkgs.bear

        # Scripts
        firstTimeSetupScript
        configureInfoScript
        jlinkDebuggerScript
        vscodeSetupScript
        setupVscodeScript
        updateScript
        clangdInit
        motdScript
      ];

      commonShellHook = ''
        # Environment variables (same as WSL image)
        export SOURCELIB_ROOT="$HOME/csse3010/sourcelib"

        # Use a separate gitconfig so we don't touch the user's ~/.gitconfig
        export GIT_CONFIG_GLOBAL="$HOME/.config/csse3010/gitconfig"
        mkdir -p "$(dirname "$GIT_CONFIG_GLOBAL")"

        # Add sourcelib tools to PATH
        if [ -d "$HOME/csse3010/sourcelib/tools" ]; then
          export PATH="$HOME/csse3010/sourcelib/tools:$PATH"
        fi
        export PATH="$HOME/.local/bin:$PATH"

        # sudo wrapper: prepend to PATH so it shadows /usr/bin/sudo
        export PATH="${sudoWrapper}/bin:$PATH"
        hash -r

        ${pkgs.lib.optionalString isLinux ''
          # LD_LIBRARY_PATH for JLink (Linux only)
          if command -v JLinkExe &>/dev/null; then
            JLINK_DIR="$(dirname "$(command -v JLinkExe)")"
            export LD_LIBRARY_PATH="''${JLINK_DIR}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
          fi
        ''}

        ${pkgs.lib.optionalString isDarwin ''
          # macOS: warn if JLink is not installed
          if ! command -v JLinkGDBServerCL &>/dev/null; then
            printf '\e[33m[WARNING] SEGGER JLink tools not found on PATH.\e[0m\n'
            printf '\e[33mPlease install JLink from: https://www.segger.com/downloads/jlink/\e[0m\n'
            echo ""
          fi
        ''}

        # Keep sourcelib in sync (background, same as WSL image)
        if [ -d "$HOME/csse3010/sourcelib/.git" ]; then
          (
            ${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" fetch --all &>/dev/null || exit 0
            LOCAL=$(${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" rev-parse HEAD 2>/dev/null)
            REMOTE=$(${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" rev-parse origin/main 2>/dev/null)
            DIRTY=$(${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" status --porcelain 2>/dev/null)

            if [ -n "$DIRTY" ] || [ "$LOCAL" != "$REMOTE" ]; then
              ${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" reset --hard origin/main &>/dev/null
              ${pkgs.git}/bin/git -C "$HOME/csse3010/sourcelib" clean -fd &>/dev/null
            fi
          ) & disown
        fi

        # Launch background setup scripts (mirror WSL systemd oneshots)
        ${generateSshKeysScript} &>/dev/null &
        ${setupSourcelibScript} &>/dev/null &

        # Auto-trigger first-time setup (same as WSL interactiveShellInit)
        if ! grep -q "lichen" "$HOME/.ssh/config" 2>/dev/null; then
          csse3010-first-setup
        fi

        clear
        motd
        cd ~

        # Must be last: ensure sudo wrapper is at front of PATH
        export PATH="${sudoWrapper}/bin:$PATH"
        hash -r
      '';

    in {
      # Default: for macOS and non-NixOS Linux (no bundled VS Code)
      default = pkgs.mkShell {
        name = "csse3010";
        packages = commonPackages ++ linuxOnlyPackages;
        shellHook = commonShellHook;
      };

      # NixOS: includes VS Code with extensions pre-installed
      nixos = pkgs.mkShell {
        name = "csse3010-nixos";
        packages = commonPackages ++ linuxOnlyPackages ++ [ vscode ];
        shellHook = commonShellHook;
      };
    });
  };
}
