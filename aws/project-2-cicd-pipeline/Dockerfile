# This tells Docker how to package your app.

# Base image: official Node.js 24 (current LTS) running on Alpine Linux.
# It already contains the `node` and `npm` binaries, so the container can run
# app.js without installing Node on the host. Alpine keeps the image small.
FROM node:24-alpine

# Create /app inside the container and make it the working directory.
# Every command below runs from here, and the app files will live here.
WORKDIR /app

# Copy only the dependency manifests first (package.json + package-lock.json).
# Docker caches this layer, so the install only re-runs when dependencies
# change, not every time app.js changes.
COPY package*.json ./

# Install exactly what package-lock.json pins into /app/node_modules.
# `npm ci` is reproducible and faster than `npm install`; dev dependencies
# are skipped since this image only runs the app.
RUN npm ci --omit=dev

# Copy the rest of the project from your machine into the image (app.js, etc.).
# .dockerignore keeps node_modules, .git and logs out of the build context.
COPY . .

# Document that the app listens on port 3001 inside the container.
# EXPOSE is metadata only; you still publish the port with `docker run -p`.
EXPOSE 3001

# Command that runs when the container starts. This is what package.json's
# "start" script does, but invoking node directly makes it PID 1 so it receives
# SIGTERM/SIGINT itself and the server.close() handler can drain cleanly.
CMD ["node", "app.js"]
