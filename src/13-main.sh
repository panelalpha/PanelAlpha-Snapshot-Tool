# ======================
# ERROR HANDLER
# ======================

error_handler() {
    local exit_code=$?
    local line_number="${1:-unknown}"
    log ERROR "Unexpected error at line $line_number (exit code: $exit_code)"
    log ERROR "Check logs: /var/log/pasnap.log"
    cleanup_temp_dir
    exit "$exit_code"
}

trap 'error_handler $LINENO' ERR

# ======================
# INITIALIZATION
# ======================

detect_installation
load_configuration

# ======================
# MAIN ENTRY POINT
# ======================

main() {
    if [[ "${1:-}" == "--update" ]]; then
        log INFO "Forcing update check..."
        PASNAP_SKIP_UPDATE_CHECK=0 \
        PASNAP_FORCE_UPDATE_CHECK=1 \
        PASNAP_AUTO_UPDATE=1 \
        PASNAP_DISABLE_AUTO_UPDATE=0 \
            check_for_updates "$@"
        exit 0
    fi

    check_for_updates "$@"

    if [[ $# -eq 0 ]]; then
        echo "$SCRIPT_NAME v$SCRIPT_VERSION"
        echo ""
        echo "No arguments provided. Use --help for options."
        echo ""
        echo "Quick start:"
        echo "  1. sudo $0 --install     # Install required tools"
        echo "  2. sudo $0 --setup       # Configure snapshot repository"
        echo "  3. sudo $0 --snapshot    # Create first snapshot"
        echo "  Or:  sudo $0 --quickstart  # All three in one step"
        echo ""
        echo "Full help: sudo $0 --help"
        exit 0
    fi

    case "${1:-}" in
        --install)
            install_dependencies
            ;;
        --setup)
            setup_config
            ;;
        --quickstart)
            quickstart
            ;;
        --snapshot)
            create_snapshot
            ;;
        --snapshot-bg)
            local bg_log="${LOG_FILE:-/var/log/pasnap.log}"
            nohup bash -c "exec $0 --snapshot" >> "$bg_log" 2>&1 &
            local nohup_pid=$!
            disown "$nohup_pid" 2>/dev/null || true
            sleep 0.5
            local bg_pid=""
            bg_pid=$(pgrep -P "$nohup_pid" 2>/dev/null || echo "")
            [[ -z "$bg_pid" ]] && bg_pid="$nohup_pid"
            log INFO "Snapshot started in background (PID: $bg_pid)"
            log INFO "Process continues even if terminal closes"
            log INFO "Monitor progress: tail -f $bg_log"
            ;;
        --test-connection)
            test_repository_connection
            ;;
        --verify-database)
            verify_database_connections
            ;;
        --restore)
            if [[ -z "${2:-}" ]]; then
                log ERROR "Snapshot ID required"
                log ERROR "Usage: $0 --restore <snapshot_id|latest>"
                log ERROR "Use '$0 --list-snapshots' to see available snapshots"
                exit 1
            fi
            if [[ "$2" != "latest" ]]; then
                validate_input "$2" "snapshot_id" || exit 1
            fi
            restore_from_snapshot "$2"
            ;;
        --list-snapshots)
            list_snapshots
            ;;
        --delete-snapshots)
            if [[ -z "${2:-}" ]]; then
                log ERROR "Snapshot ID required"
                log ERROR "Usage: $0 --delete-snapshots <snapshot_id>"
                exit 1
            fi
            validate_input "$2" "snapshot_id" || exit 1
            delete_snapshot "$2"
            ;;
        --cron)
            if [[ -z "${2:-}" ]] || [[ ! "${2:-}" =~ ^(install|remove|status)$ ]]; then
                log ERROR "Usage: $0 --cron [install|remove|status]"
                exit 1
            fi
            manage_cron "$2"
            ;;
        --version)
            show_version
            ;;
        --help|-h)
            show_help
            ;;
        *)
            log ERROR "Unknown option: ${1:-}"
            echo ""
            echo "Use '$0 --help' to see available options"
            echo ""
            echo "Common commands:"
            echo "  sudo $0 --snapshot         # Create snapshot"
            echo "  sudo $0 --list-snapshots   # View snapshots"
            echo "  sudo $0 --restore latest   # Restore latest"
            exit 1
            ;;
    esac
}

main "$@"
