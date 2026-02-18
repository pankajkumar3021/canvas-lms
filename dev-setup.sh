#!/usr/bin/env bash
# =============================================================
# Canvas LMS – Developer Environment Setup Script
#
# Usage:
#   ./dev-setup.sh            Full setup (first time)
#   ./dev-setup.sh --start    Start existing instance only
#   ./dev-setup.sh --update   Pull code + migrate + restart
#   ./dev-setup.sh --rebuild  Rebuild Docker images + restart
#
# What this script does NOT do:
#   - Build Docker images from scratch (uses existing images
#     if present, or pulls from Docker build cache)
#   - Require Ruby/Node/PostgreSQL on the host
#   - Require root (uses sudo only where necessary)
# =============================================================

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}[OK]${RESET} $*"; }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
die()  { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}==> $*${RESET}"; }

# ── Parse arguments ───────────────────────────────────────────
MODE="full"
case "${1:-}" in
  --start)   MODE="start"   ;;
  --update)  MODE="update"  ;;
  --rebuild) MODE="rebuild" ;;
  --help|-h)
    echo "Usage: $0 [--start | --update | --rebuild]"
    echo ""
    echo "  (no args)   Full first-time setup"
    echo "  --start     Start existing containers only"
    echo "  --update    Pull code + migrate + restart"
    echo "  --rebuild   Rebuild Docker images + start"
    exit 0
    ;;
esac

# ── Verify we're in the canvas-lms root ───────────────────────
if [[ ! -f "docker-compose.yml" ]] || ! grep -q "Canvas LMS" README.md 2>/dev/null; then
  die "Run this script from the canvas-lms root directory."
fi

# ── Check Docker is running ───────────────────────────────────
check_docker() {
  step "Checking Docker"
  if ! docker info &>/dev/null; then
    die "Docker is not running. Start it with: sudo systemctl start docker"
  fi
  ok "Docker is running"
  if ! docker compose version &>/dev/null; then
    die "Docker Compose v2 not found. Install: sudo apt install docker-compose-plugin"
  fi
  ok "Docker Compose v2 found"
}

# ── Fix .git ownership (Docker sets files to uid 9999) ────────
fix_git_permissions() {
  if [[ -d ".git" ]]; then
    GIT_OWNER=$(stat -c '%U' .git 2>/dev/null || echo "unknown")
    if [[ "$GIT_OWNER" != "$USER" ]]; then
      info "Fixing .git directory ownership (currently owned by '$GIT_OWNER')..."
      sudo chown -R "$USER":"$USER" .git
      ok ".git ownership fixed"
    fi
  fi
}

# ── Check required config files exist ─────────────────────────
check_config_files() {
  step "Checking configuration files"
  REQUIRED_CONFIGS=(
    "config/domain.yml"
    "config/database.yml"
    "config/redis.yml"
    "config/security.yml"
    "docker-compose.override.yml"
  )
  MISSING=0
  for f in "${REQUIRED_CONFIGS[@]}"; do
    if [[ -f "$f" ]]; then
      ok "$f"
    else
      warn "$f is missing"
      MISSING=1
    fi
  done
  if [[ $MISSING -eq 1 ]]; then
    die "Missing config files. See INSTALL.md Section 3 for setup instructions."
  fi
}

# ── Build Docker images ───────────────────────────────────────
build_images() {
  step "Building Docker images"
  info "This may take 15-30 minutes on first run..."
  docker compose build
  ok "Images built"
}

# ── Start all containers ──────────────────────────────────────
start_services() {
  step "Starting all services"
  docker compose up -d
  ok "Services started"
}

# ── Wait for postgres to be ready ─────────────────────────────
wait_for_postgres() {
  step "Waiting for PostgreSQL to be ready"
  RETRIES=30
  until docker compose exec -T postgres pg_isready -U postgres &>/dev/null; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -eq 0 ]]; then
      die "PostgreSQL did not become ready in time."
    fi
    echo -n "."
    sleep 2
  done
  echo ""
  ok "PostgreSQL is ready"
}

# ── Initialize database (first-time only) ─────────────────────
init_database() {
  step "Initializing database"
  # Check if DB already exists
  if docker compose run --rm web bundle exec rails runner \
       'ActiveRecord::Base.connection; puts "exists"' 2>/dev/null | grep -q "exists"; then
    info "Database already exists — running migrations only"
    docker compose run --rm web bundle exec rake db:migrate
  else
    info "Creating and seeding database (this takes a few minutes)..."
    docker compose run --rm web bundle exec rake db:create db:initial_setup
  fi
  ok "Database ready"
}

# ── Run DB migrations ─────────────────────────────────────────
run_migrations() {
  step "Running database migrations"
  docker compose run --rm web bundle exec rake db:migrate
  ok "Migrations complete"
}

# ── Install gems ──────────────────────────────────────────────
bundle_install() {
  step "Installing Ruby gems"
  docker compose run --rm web bundle install
  ok "Gems installed"
}

# ── Install JS packages ───────────────────────────────────────
yarn_install() {
  step "Installing Node packages"
  docker compose run --rm web yarn install
  ok "Node packages installed"
}

# ── Wait for webpack to finish compiling ──────────────────────
wait_for_webpack() {
  step "Waiting for Webpack to compile assets"
  info "This may take 2-5 minutes on first boot..."
  RETRIES=60
  until docker compose logs webpack 2>/dev/null | grep -q "compiled successfully"; do
    RETRIES=$((RETRIES - 1))
    if [[ $RETRIES -eq 0 ]]; then
      warn "Webpack hasn't finished yet — the site will load once it does."
      info "Monitor with: docker compose logs -f webpack"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  ok "Webpack compiled successfully"
}

# ── Print final status ────────────────────────────────────────
print_status() {
  step "Service Status"
  docker compose ps
  echo ""
  echo -e "${BOLD}Canvas LMS is running!${RESET}"
  echo ""
  echo -e "  Local:   ${GREEN}http://localhost:3001${RESET}"
  echo -e "  Domain:  ${GREEN}https://lms.mygradex.com${RESET}  (if Nginx+SSL configured)"
  echo ""
  echo "Useful commands:"
  echo "  docker compose logs -f web       # Rails logs"
  echo "  docker compose logs -f webpack   # Asset compilation"
  echo "  docker compose run --rm web rails console"
  echo "  docker compose down              # Stop all services"
  echo ""
}

# ── Pull latest code from personal fork ───────────────────────
pull_code() {
  step "Pulling latest code from personal fork"
  if git remote get-url personal &>/dev/null; then
    git pull personal master
    ok "Code updated"
  else
    warn "Remote 'personal' not configured. Skipping pull."
    info "To add it: git remote add personal git@github.com:pankajkumar3021/canvas-lms.git"
  fi
}

# ── Restart web and jobs containers ───────────────────────────
restart_app() {
  step "Restarting application containers"
  docker compose restart web jobs
  ok "Containers restarted"
}

# =============================================================
# MAIN
# =============================================================

check_docker
fix_git_permissions

case "$MODE" in

  full)
    # ── First-time full setup ──────────────────────────────────
    step "Starting full Canvas LMS dev setup"
    check_config_files
    # Only build if images don't exist yet
    if ! docker images | grep -q "canvas-lms-web"; then
      build_images
    else
      info "Docker images already exist — skipping build."
      info "Run with --rebuild to force a rebuild."
    fi
    start_services
    wait_for_postgres
    init_database
    wait_for_webpack
    print_status
    ;;

  start)
    # ── Start existing instance (no rebuild, no migration) ────
    step "Starting existing Canvas LMS instance"
    check_config_files
    start_services
    wait_for_webpack
    print_status
    ;;

  update)
    # ── Pull code + migrate + restart ─────────────────────────
    step "Updating Canvas LMS"
    pull_code
    run_migrations
    restart_app
    print_status
    ;;

  rebuild)
    # ── Full image rebuild + restart ──────────────────────────
    step "Rebuilding Canvas LMS Docker images"
    docker compose down
    build_images
    bundle_install
    yarn_install
    start_services
    wait_for_postgres
    run_migrations
    wait_for_webpack
    print_status
    ;;

esac
