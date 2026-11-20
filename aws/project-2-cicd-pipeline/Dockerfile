# This tells Docker how to package your app.

# Base image: official Node.js 18 running on Alpine Linux.
# It already contains the `node` and `npm` binaries, so the container can run
# app.js without installing Node on the host. Alpine keeps the image small.
# Note: Node 18 reached end-of-life in April 2025; node:24-alpine is the
# current LTS when you're ready to upgrade.
FROM node:18-alpine

# Create /app inside the container and make it the working directory.
# Every command below runs from here, and the app files will live here.
WORKDIR /app

# Copy only the dependency manifests first (package.json + package-lock.json).
# Docker caches this layer, so `npm install` only re-runs when dependencies
# change, not every time app.js changes.
COPY package*.json ./

# Install the dependencies listed in package.json into /app/node_modules.
# (`npm ci --omit=dev` would be stricter/faster for production images.)
RUN npm install

# Copy the rest of the project from your machine into the image (app.js, etc.).
# A .dockerignore file can exclude node_modules, .git, and other local files.
COPY . .

# Document that the app listens on port 3001 inside the container.
# EXPOSE is metadata only; you still publish the port with `docker run -p`.
EXPOSE 3001

# Command that runs when the container starts.
# `npm start` runs the "start" script from package.json, i.e. `node app.js`.
# Running node directly would make it PID 1 and receive SIGTERM more cleanly.
CMD ["npm", "start"]
