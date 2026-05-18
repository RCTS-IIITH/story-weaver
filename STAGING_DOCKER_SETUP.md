# StoryWeaver Staging Setup

This document covers the full Docker-based staging setup for the StoryWeaver platform on the client server.

## Architecture

```
Internet
  └─ Host Nginx (port 443, SSL)          ← already configured on your server
       └─ Docker Nginx (port 8080)        ← provided in this setup
            ├─ /node/api/*    → sw-nodejs:8000
            ├─ /assets/       → spp:3000  (Rails static assets)
            ├─ /system/       → spp:3000  (uploaded files)
            ├─ /v0/, /editor/, /users/, /api/  → spp:3000
            └─ /*             → sw-js:3000 (React SPA)
```

## Services

| Service | Container | Notes |
|---|---|---|
| PostgreSQL 16 | `sw_postgres` | Internal only — not exposed |
| Redis 7 | `sw_redis` | Internal only — not exposed |
| Elasticsearch 8.11 | `sw_elasticsearch` | Internal only — not exposed |
| spp (Rails) | `sw_rails` | Internal only |
| worker (Delayed::Job) | `sw_worker` | Internal only |
| sw-nodejs | `sw_nodejs` | Internal only |
| sw-js (React frontend) | `sw_frontend` | Internal only |
| **Nginx** | `sw_nginx` | **port 8080** ← Docker entry point |

---

## Prerequisites

- Docker and Docker Compose installed on the server
- Host Nginx already configured with SSL for your domain
- Docker Hub credentials to pull images (provided separately)

---

## 0. Host Nginx Configuration

Your host Nginx should proxy all traffic to Docker Nginx on port 8080. Add this to your site config:

```nginx
location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
```

Then reload host Nginx:

```bash
sudo nginx -t && sudo nginx -s reload
```

---

## 1. Place the files

Copy the following files from the delivery package onto your server into a single directory (e.g. `/opt/storyweaver`):

```
docker-compose-staging.yml
.env.staging
nginx.staging.conf
uat_db_backup.psql          ← database dump (provided separately)
```

---

## 2. Configure `.env.staging`

Open `.env.staging` and fill in the values marked below. Everything else is pre-configured.

```bash
# ── Required: fill these in ──────────────────────────────────────────────────

# Generate with: openssl rand -hex 64  (run twice, one value each)
SECRET_KEY_BASE=<generate>
DEVISE_SECRET_KEY_BASE=<generate>

# Email sending credentials
MAIL_USERNAME=<your-smtp-username>
MAIL_PASSWORD=<your-smtp-password>

# ── Already set — verify these match your environment ────────────────────────

ROOT_URL=https://pl-api.iiit.ac.in
VITE_GOOGLE_CLIENT_ID=<provided>
```

Generate the secret keys:

```bash
openssl rand -hex 64   # run twice — one value for each key
```

---

## 3. Log in to Docker Hub

```bash
docker login
# enter Docker Hub credentials when prompted
```

---

## 4. Pull the images

```bash
docker compose -f docker-compose-staging.yml pull
```

---

## 5. Start infrastructure

```bash
docker compose -f docker-compose-staging.yml up -d postgres redis elasticsearch
```

Wait for all three to be healthy:

```bash
docker compose -f docker-compose-staging.yml ps
```

All three should show `healthy` before proceeding.

---

## 6. Restore the database

```bash
docker compose -f docker-compose-staging.yml exec postgres dropdb -U spp_user --if-exists spp
docker compose -f docker-compose-staging.yml exec postgres createdb -U spp_user spp
cat uat_db_backup.psql | docker compose -f docker-compose-staging.yml exec -T postgres pg_restore -U spp_user -d spp --no-owner --no-privileges
```

---

## 7. Run database migrations

Fix older Rails migration files before running (one-time only):

```bash
docker compose -f docker-compose-staging.yml run --rm spp bash -c "find db/migrate -type f -exec sed -i 's/ActiveRecord::Migration\[4\.2\]/ActiveRecord::Migration[6.1]/' {} \;"
docker compose -f docker-compose-staging.yml run --rm spp bash -c "find db/migrate -type f -exec sed -i 's/\.update_attributes(/.update(/' {} \;"
```

Run Rails migrations:

```bash
docker compose -f docker-compose-staging.yml run --rm spp bundle exec rake db:migrate
```

Run Sequelize (Node.js) migrations:

```bash
docker compose -f docker-compose-staging.yml run --rm sw-nodejs npx sequelize-cli db:migrate
```

---

## 8. Start all services

```bash
docker compose -f docker-compose-staging.yml up -d
```

**Startup order is automatic:**
1. Infrastructure (postgres, redis, elasticsearch) starts and waits until healthy
2. sw-js starts and populates the shared asset volume (pre-built in the image — fast)
3. spp starts after sw-js is healthy and copies frontend assets
4. nginx starts last

Check everything is running:

```bash
docker compose -f docker-compose-staging.yml ps
```

The app should be accessible at your domain once nginx shows as running.

---

## 9. Reindex Elasticsearch (first time after DB restore)

The database dump does not include Elasticsearch indices. Run these after the DB restore.

> `language:reindex` must run first — other indices depend on it.

### Partial reindex (recommended — indexes a representative sample)

```bash
# Languages first (required)
docker compose -f docker-compose-staging.yml exec spp bundle exec rake language:reindex

# 5000 users
docker compose -f docker-compose-staging.yml exec spp bundle exec rails runner "User.limit(5000).reindex"

# 5000 stories
docker compose -f docker-compose-staging.yml exec spp bundle exec rails runner "Story.limit(5000).reindex"

# Illustrations for those same 5000 stories
docker compose -f docker-compose-staging.yml exec spp bundle exec rails runner "
  story_ids  = Story.limit(5000).pluck(:id)
  illust_ids = IllustrationCrop.joins(:pages).where(pages: { story_id: story_ids }).pluck(:illustration_id).uniq
  Illustration.where(id: illust_ids).reindex
"

# Remaining indices (small tables)
docker compose -f docker-compose-staging.yml exec spp bundle exec rake list:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake organization:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake blog_posts:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake globalAutoSuggestionWord:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake translatorStory:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake userFlaggedIllustrationsSearch:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake userFlaggedStoriesSearch:reindex
```

### Full reindex (production-accurate, takes longer)

```bash
docker compose -f docker-compose-staging.yml exec spp bundle exec rake language:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rails runner "Story.reindex"
docker compose -f docker-compose-staging.yml exec spp bundle exec rake list:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake illustrations:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake organization:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake blog_posts:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake globalAutoSuggestionWord:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake translatorStory:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake userFlaggedIllustrationsSearch:reindex
docker compose -f docker-compose-staging.yml exec spp bundle exec rake userFlaggedStoriesSearch:reindex
```

---

## 10. Useful commands

Tail logs:

```bash
docker compose -f docker-compose-staging.yml logs -f spp
docker compose -f docker-compose-staging.yml logs -f sw-nodejs
docker compose -f docker-compose-staging.yml logs -f sw-js
```

Check service status:

```bash
docker compose -f docker-compose-staging.yml ps
```

Rails console:

```bash
docker compose -f docker-compose-staging.yml exec spp bundle exec rails console
```

---

## 11. Updating to a new image version

When a new set of images is delivered:

1. Update the image tags in `.env.staging`:
   ```
   SPP_IMAGE_TAG=<new-tag>
   NODEJS_IMAGE_TAG=<new-tag>
   FRONTEND_IMAGE_TAG=<new-tag>
   ```

2. Pull and restart:
   ```bash
   docker compose -f docker-compose-staging.yml pull
   docker compose -f docker-compose-staging.yml up -d
   ```

3. Run any new migrations if instructed:
   ```bash
   docker compose -f docker-compose-staging.yml exec spp bundle exec rake db:migrate
   docker compose -f docker-compose-staging.yml exec sw-nodejs npx sequelize-cli db:migrate
   ```

---

## Stop / Reset

Stop containers, keep data:

```bash
docker compose -f docker-compose-staging.yml down
```

Full reset (deletes all data — use with caution):

```bash
docker compose -f docker-compose-staging.yml down -v
```
