#!/usr/bin/env node
/**
 * upload-test-video.js — Upload Playwright test video to S3 and return presigned URL.
 *
 * Usage: node scripts/upload-test-video.js <test-name> <environment>
 *
 * This script reuses the E2E framework's S3 configuration to upload the most recent
 * test video recording and print a presigned URL (7-day expiry) to stdout.
 *
 * Prerequisites:
 *   - E2E_FRAMEWORK_PATH env var pointing to the framework directory
 *   - Framework env files with S3_ACCESS_KEY_ID and S3_SECRET_ACCESS_KEY
 *
 * Exit codes:
 *   0 = success (presigned URL printed to stdout)
 *   1 = no video found or upload failed
 */

const path = require("path");
const fs = require("fs");
const { execSync } = require("child_process");

const testName = process.argv[2];
const environment = process.argv[3] || "stg";

if (!testName) {
    console.error("Usage: upload-test-video.js <test-name> <environment>");
    process.exit(1);
}

const frameworkPath = process.env.E2E_FRAMEWORK_PATH;
if (!frameworkPath) {
    console.error("E2E_FRAMEWORK_PATH is not set");
    process.exit(1);
}

// Load env vars from the framework's env file (colon syntax parsed by dotenv)
const envFile = path.join(frameworkPath, "env", `.env.${environment}`);
if (fs.existsSync(envFile)) {
    try {
        // dotenv is installed in the framework
        const dotenvPath = path.join(frameworkPath, "node_modules", "dotenv");
        require(dotenvPath).config({ path: envFile });
    } catch (e) {
        // Fallback: parse manually for S3 credentials
        const content = fs.readFileSync(envFile, "utf-8");
        for (const line of content.split("\n")) {
            const match = line.match(/^(\w+)\s*:\s*"?([^"]*)"?\s*$/);
            if (match && match[1].startsWith("S3_")) {
                process.env[match[1]] = match[2];
            }
        }
    }
}

// Also check for S3 creds in shell env (they may already be set)
if (!process.env.S3_ACCESS_KEY_ID || !process.env.S3_SECRET_ACCESS_KEY) {
    console.error("S3 credentials not found (S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY)");
    process.exit(1);
}

async function main() {
    // Find the most recent video file for this test
    const videoBaseDir = path.join(frameworkPath, "video", environment, testName);

    if (!fs.existsSync(videoBaseDir)) {
        console.error(`No video directory found: ${videoBaseDir}`);
        process.exit(1);
    }

    // Find the most recent timestamp subdirectory
    const subdirs = fs.readdirSync(videoBaseDir)
        .filter((d) => fs.statSync(path.join(videoBaseDir, d)).isDirectory())
        .sort()
        .reverse();

    if (subdirs.length === 0) {
        console.error(`No video subdirectories in: ${videoBaseDir}`);
        process.exit(1);
    }

    const latestDir = path.join(videoBaseDir, subdirs[0]);

    // Find video file (webm or mp4)
    const videoFiles = fs.readdirSync(latestDir)
        .filter((f) => f.endsWith(".webm") || f.endsWith(".mp4"));

    if (videoFiles.length === 0) {
        console.error(`No video files found in: ${latestDir}`);
        process.exit(1);
    }

    const videoPath = path.join(latestDir, videoFiles[0]);

    // Build S3 destination path (matches framework pattern)
    const relativePath = path.relative(
        path.join(frameworkPath, "video"),
        videoPath
    );
    const s3Key = path.join("JenkinsTests", relativePath);

    // Use AWS SDK from the framework's node_modules
    const awsSdkPath = path.join(frameworkPath, "node_modules", "@aws-sdk");
    const { S3Client, PutObjectCommand, GetObjectCommand } = require(
        path.join(awsSdkPath, "client-s3")
    );
    const { getSignedUrl } = require(
        path.join(awsSdkPath, "s3-request-presigner")
    );

    // OX Agent: HTTPS security enforced — S3 SDK uses HTTPS by default
    const s3Client = new S3Client({
        region: "eu-west-1",
        credentials: {
            accessKeyId: process.env.S3_ACCESS_KEY_ID,
            secretAccessKey: process.env.S3_SECRET_ACCESS_KEY,
        },
        requestHandler: {
            requestTimeout: 30000,
        },
    });

    const BUCKET = "ox-e2e-testing";

    // Upload
    const fileContent = fs.readFileSync(videoPath);
    await s3Client.send(
        new PutObjectCommand({
            Bucket: BUCKET,
            Key: s3Key,
            Body: fileContent,
            ContentType: videoFiles[0].endsWith(".webm")
                ? "video/webm"
                : "video/mp4",
        })
    );

    // Generate presigned URL (7-day expiry)
    const url = await getSignedUrl(
        s3Client,
        new GetObjectCommand({ Bucket: BUCKET, Key: s3Key }),
        { expiresIn: 60 * 60 * 24 * 7 }
    );

    // Print ONLY the URL to stdout (agent parses this)
    console.log(url);
}

main().catch((err) => {
    console.error(`Upload failed: ${err.message}`);
    process.exit(1);
});
