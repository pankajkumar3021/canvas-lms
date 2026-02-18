# Canvas LMS – Developer Guide

**Stack:** Ruby on Rails · React/TypeScript · PostgreSQL · Redis · Docker

This guide covers day-to-day development: making code changes,
testing them inside Docker, and deploying updates to the live instance.

---

## Table of Contents

1. [Dev Environment Setup](#1-dev-environment-setup)
2. [Project Structure](#2-project-structure)
3. [Running the Dev Instance](#3-running-the-dev-instance)
4. [Making Code Changes](#4-making-code-changes)
5. [Testing Changes](#5-testing-changes)
6. [Deploying to the Live Instance](#6-deploying-to-the-live-instance)
7. [Common Developer Tasks](#7-common-developer-tasks)
8. [Git Workflow](#8-git-workflow)

---

## 1. Dev Environment Setup

> Use `dev-setup.sh` (in the repo root) for an automated setup.
> See the script for a one-command install.

### Manual steps (if you prefer)

**Prerequisites on the host:**

```bash
# Docker Engine + Compose
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # log out and back in

# Git + SSH key for GitHub
sudo apt install git
ssh-keygen -t ed25519 -C "you@example.com"
# Add ~/.ssh/id_ed25519.pub to GitHub -> Settings -> SSH keys
```

**Clone your fork:**

```bash
git clone git@github.com:pankajkumar3021/canvas-lms.git
cd canvas-lms
```

**Add upstream remote (to pull Instructure updates later):**

```bash
git remote add upstream https://github.com/instructure/canvas-lms.git
```

**Fix .git directory permissions** (Docker sets files to uid 9999):

```bash
sudo chown -R $USER:$USER .git
```

**Set git identity:**

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

---

## 2. Project Structure

```
canvas-lms/
├── app/
│   ├── controllers/        # Rails controllers
│   ├── models/             # ActiveRecord models
│   ├── views/              # ERB templates
│   │   └── login/canvas/   # Login page partials ← Gradex branding here
│   └── stylesheets/        # CSS/SCSS
├── ui/                     # React components (TypeScript)
│   └── features/
│       └── new_login/      # New login UI feature
├── config/
│   ├── domain.yml          # Domain + SSL config
│   ├── database.yml        # DB connection (uses env vars)
│   ├── redis.yml           # Redis connection
│   ├── security.yml        # Encryption keys
│   └── outgoing_mail.yml   # SMTP config
├── db/
│   └── migrate/            # Database migrations
├── spec/                   # RSpec tests (Ruby)
├── packages/               # Shared npm packages
├── docker-compose.yml      # Base Docker config
├── docker-compose.override.yml  # Host-specific overrides
├── Dockerfile              # Main application image
└── INSTALL.md              # Full installation guide
```

**Key customisation files for Gradex:**

| File | What it changes |
|---|---|
| `app/views/login/canvas/_new_login_content.html.erb` | Login page footer (Gradex branding) |
| `config/domain.yml` | Domain set to `lms.mygradex.com` |
| `config/security.yml` | Encryption key + LTI issuer |
| `docker-compose.override.yml` | Ports, env vars, volumes |

---

## 3. Running the Dev Instance

The dev instance runs entirely inside Docker. You do **not** need
Ruby, Node, or PostgreSQL installed on the host.

### Start all services

```bash
cd canvas-lms
docker compose up -d
```

### Check everything is running

```bash
docker compose ps
```

Expected output:

```
canvas-lms-web-1       Up    0.0.0.0:3001->80/tcp
canvas-lms-jobs-1      Up
canvas-lms-webpack-1   Up
canvas-lms-postgres-1  Up    5432/tcp
canvas-lms-redis-1     Up    6379/tcp
```

### Access the running instance

- **Direct (no SSL):** `http://localhost:3001`
- **Via domain (with Nginx + SSL):** `https://lms.mygradex.com`

### Watch logs in real time

```bash
docker compose logs -f web      # Rails app
docker compose logs -f webpack  # Asset compilation (wait for "compiled successfully")
docker compose logs -f jobs     # Background jobs
```

### Stop the instance

```bash
docker compose down             # stop, keep data
docker compose down -v          # stop + delete all volumes (wipes DB!)
```

---

## 4. Making Code Changes

### Ruby / Rails changes (controllers, models, views, ERB)

These take effect **immediately** — no restart needed.
The source directory is mounted as a volume into the container:
`.:/usr/src/app`

Edit files normally on the host, then refresh the browser.

**Example — edit the login footer:**

```bash
# On the host, open your editor:
code app/views/login/canvas/_new_login_content.html.erb

# Refresh browser — change is live immediately
```

### React / TypeScript / JavaScript changes

Webpack watches for changes and recompiles automatically.

```bash
# Watch webpack output to see when recompile finishes:
docker compose logs -f webpack
```

Edit files under `ui/` on the host. Webpack recompiles within
a few seconds and the browser hot-reloads.

### Ruby gem changes (`Gemfile`)

After editing `Gemfile`, run bundle install inside the container:

```bash
docker compose run --rm web bundle install
docker compose restart web
```

### CSS / SCSS changes

```bash
docker compose run --rm web bundle exec rake canvas:compile_assets_dev
```

Or for just CSS:

```bash
docker compose run --rm web yarn build:css
```

### Database migrations

After creating a new migration file under `db/migrate/`:

```bash
docker compose run --rm web bundle exec rake db:migrate
```

---

## 5. Testing Changes

### Run Ruby (RSpec) tests

```bash
# All tests
docker compose run --rm web bin/rspec

# A specific file
docker compose run --rm web bin/rspec spec/models/user_spec.rb

# A specific line
docker compose run --rm web bin/rspec spec/models/user_spec.rb:42

# A specific folder
docker compose run --rm web bin/rspec spec/controllers/
```

### Run JavaScript / TypeScript tests

```bash
# All JS tests
docker compose run --rm web yarn test

# A specific file
docker compose run --rm web yarn test ui/features/new_login/

# Watch mode (re-runs on file changes)
docker compose run --rm web yarn test:watch
```

### Type checking (TypeScript)

```bash
docker compose run --rm web yarn check:ts
```

### Linting

```bash
# JavaScript / TypeScript
docker compose run --rm web yarn lint

# Ruby
docker compose run --rm web bin/rubocop

# Biome (JS formatter)
docker compose run --rm web yarn check:biome
```

### Rails console (manual testing)

```bash
docker compose run --rm web rails console
```

Useful console commands:

```ruby
# Find a user
User.find_by(name: "Admin User")

# Check authentication providers
Account.default.authentication_providers.pluck(:auth_type, :id)

# Check feature flags
Account.default.feature_enabled?(:login_registration_ui_identity)

# Fix Google hosted_domain restriction
Account.default.authentication_providers
       .where(auth_type: "google").first
       .update!(hosted_domain: nil)
```

---

## 6. Deploying to the Live Instance

The live instance runs on the same host under Docker. A "deploy"
means pulling your changes from GitHub and restarting the web container.

### Standard deploy (code-only changes)

```bash
cd /home/pkumar02/canvas-lms

# 1. Pull latest code from your fork
git pull personal master

# 2. Restart the web container to pick up the changes
#    (no rebuild needed for ERB/Ruby/view changes)
docker compose restart web
```

### Deploy with new migrations

```bash
git pull personal master
docker compose run --rm web bundle exec rake db:migrate
docker compose restart web jobs
```

### Deploy with new JS/CSS assets

```bash
git pull personal master
docker compose run --rm web yarn install
docker compose run --rm web bundle exec rake canvas:compile_assets_dev
docker compose restart web
```

### Full rebuild (Gemfile changed or Dockerfile changed)

```bash
git pull personal master
docker compose build
docker compose run --rm web bundle install
docker compose run --rm web bundle exec rake db:migrate
docker compose up -d
```

> A full rebuild takes 10-20 minutes the first time after a Gemfile
> change (gem download + compile). Subsequent rebuilds are faster
> due to Docker layer caching.

### Verify the deploy

```bash
# Check the web container started cleanly
docker compose logs web --tail=50

# Check the live site
curl -I https://lms.mygradex.com
```

---

## 7. Common Developer Tasks

### Open a shell inside the web container

```bash
docker compose run --rm web bash
```

### View recent application errors

```bash
docker compose logs web | grep -i error | tail -30
```

### Reset the database (destructive!)

```bash
docker compose run --rm web bundle exec rake db:drop db:create db:initial_setup
```

### Add a new feature flag

Feature flags are managed in the database via the Canvas admin UI:
**Admin -> Settings -> Feature Options**

Or via console:

```ruby
Account.default.enable_feature!(:your_feature_flag_name)
Account.default.disable_feature!(:your_feature_flag_name)
```

### Check which migrations haven't run

```bash
docker compose run --rm web bundle exec rake db:migrate:status | grep down
```

### Access PostgreSQL directly

```bash
docker exec -it canvas-lms-postgres-1 psql -U postgres canvas_development
```

### Access Redis directly

```bash
docker exec -it canvas-lms-redis-1 redis-cli
```

---

## 8. Git Workflow

### Branches

```
master      ← your production/live branch
            (tracks pankajkumar3021/canvas-lms)

upstream    ← Instructure's official repo (read-only reference)
```

### Typical change workflow

```bash
# 1. Make sure you're on master and up to date
git checkout master
git pull personal master

# 2. Edit files
code app/views/login/canvas/_new_login_content.html.erb

# 3. Test your changes (see Section 5)
docker compose restart web
# ... verify in browser ...

# 4. Commit
git add app/views/login/canvas/_new_login_content.html.erb
git commit -m "Brief description of what and why"

# 5. Push to your fork
git push personal master

# 6. Deploy to live instance (it's the same machine)
docker compose restart web
```

### Pulling upstream Canvas updates

```bash
# Fetch latest from Instructure
git fetch upstream

# Merge into your master (resolve conflicts if any)
git merge upstream/master

# Push merged result to your fork
git push personal master --force

# Run migrations if any were added
docker compose run --rm web bundle exec rake db:migrate
docker compose restart web
```

### Commit message style

```
Short imperative title (under 60 chars)

Optional: explain the why behind the change
in a second paragraph if it's not obvious.
```

Examples:

```
Customize login footer with Gradex branding
Fix Google OAuth hosted_domain restriction
Update admin email in docker-compose config
```
