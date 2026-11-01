-- AlterTable
ALTER TABLE "comments" ALTER COLUMN "public_id" SET DEFAULT 'c_' || replace(gen_random_uuid()::text, '-', '');
