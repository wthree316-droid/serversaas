/* ==========================================================================
   Project Lotto Webshop Database Schema (PostgreSQL)
   รองรับ: Supabase (PostgreSQL 15+)
   ========================================================================== */

-- 1. เปิดใช้งาน Extension ที่จำเป็น
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- 2. สร้าง ENUM Types (ถ้ามีอยู่แล้วให้ข้าม)
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('superadmin', 'admin', 'member');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

/* ==========================================================================
   ส่วนที่ 1: ร้านค้าและผู้ใช้งาน (Shops & Users)
   ========================================================================== */

-- 1.1 ตารางร้านค้า
CREATE TABLE IF NOT EXISTS shops (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    code VARCHAR(10) UNIQUE NOT NULL,
    subdomain TEXT UNIQUE,
    logo_url TEXT,
    theme_color TEXT DEFAULT '#2563EB',
    
    -- Messaging API Configs
    line_channel_token TEXT,
    line_target_id TEXT,

    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_shops_subdomain ON shops(subdomain);

-- 1.2 ตารางผู้ใช้งาน
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role user_role NOT NULL DEFAULT 'member',
    shop_id UUID REFERENCES shops(id),
    full_name TEXT,
    credit_balance DECIMAL(15, 2) DEFAULT 0.00,
    
    -- Security
    failed_attempts INT DEFAULT 0,
    locked_until TIMESTAMPTZ DEFAULT NULL,
    
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_users_shop_id ON users(shop_id);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

/* ==========================================================================
   ส่วนที่ 2: โครงสร้างหวยและหมวดหมู่ (Lotto Config)
   ========================================================================== */

-- 2.1 โปรไฟล์เรทราคา (Rate Profiles)
CREATE TABLE IF NOT EXISTS rate_profiles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    rates JSONB DEFAULT '{}', -- { "2up": 90, "3top": 900 }
    shop_id UUID REFERENCES shops(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.2 หมวดหมู่หวย (Categories)
CREATE TABLE IF NOT EXISTS lotto_categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    label VARCHAR(255) NOT NULL,
    color VARCHAR(100) DEFAULT 'bg-gray-100 text-gray-700',
    order_index INTEGER DEFAULT 999,
    shop_id UUID REFERENCES shops(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2.3 ประเภทหวย (Lotto Types)
CREATE TABLE IF NOT EXISTS lotto_types (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    code VARCHAR(20) NOT NULL,
    category VARCHAR DEFAULT 'GENERAL', -- เก็บ ID ของ Category หรือ String
    
    -- Relations
    shop_id UUID REFERENCES shops(id),
    rate_profile_id UUID REFERENCES rate_profiles(id),
    
    -- Display & Config
    img_url TEXT,
    is_template BOOLEAN DEFAULT FALSE,
    is_active BOOLEAN DEFAULT TRUE,
    
    -- Scheduling
    open_time VARCHAR(20),
    close_time VARCHAR(20),
    result_time VARCHAR(20),
    open_days JSONB DEFAULT '[]', -- ["MON", "TUE", ...]
    
    -- External & Rules
    api_link TEXT,
    rules JSONB DEFAULT '{}',
    
    created_at TIMESTAMPTZ DEFAULT NOW()
);
-- ป้องกันชื่อซ้ำในร้านเดียวกัน
CREATE UNIQUE INDEX IF NOT EXISTS uix_shop_code ON lotto_types (shop_id, code);

/* ==========================================================================
   ส่วนที่ 3: การจัดการความเสี่ยง (Risk Management)
   ========================================================================== */

-- 3.1 เลขอั้น/เลขปิด
CREATE TABLE IF NOT EXISTS number_risks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    lotto_type_id UUID NOT NULL REFERENCES lotto_types(id) ON DELETE CASCADE,
    shop_id UUID REFERENCES shops(id),
    number VARCHAR NOT NULL,
    risk_type VARCHAR NOT NULL, -- 'CLOSE', 'HALF'
    specific_bet_type VARCHAR DEFAULT 'ALL',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_risks_lotto ON number_risks (lotto_type_id, number);

/* ==========================================================================
   ส่วนที่ 4: การซื้อขายและผลรางวัล (Transactions & Results)
   ========================================================================== */

-- 4.1 ตารางบิล (Tickets)
CREATE TABLE IF NOT EXISTS tickets (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    shop_id UUID NOT NULL REFERENCES shops(id),
    user_id UUID NOT NULL REFERENCES users(id),
    lotto_type_id UUID REFERENCES lotto_types(id),
    
    round_date DATE,
    total_amount DECIMAL(15, 2) NOT NULL,
    status VARCHAR(20) DEFAULT 'PENDING', -- PENDING, WIN, LOSE, CANCELLED
    note TEXT,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_tickets_user_id ON tickets(user_id);
CREATE INDEX IF NOT EXISTS idx_tickets_created_at ON tickets(created_at);
CREATE INDEX IF NOT EXISTS idx_tickets_status ON tickets(status);

-- 4.2 รายการในบิล (Ticket Items)
CREATE TABLE IF NOT EXISTS ticket_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ticket_id UUID NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
    
    number TEXT NOT NULL,
    bet_type VARCHAR(20) NOT NULL, -- 2up, 3top, etc.
    amount DECIMAL(15, 2) NOT NULL,
    reward_rate DECIMAL(15, 2) NOT NULL,
    winning_amount DECIMAL(15, 2) DEFAULT 0.00,
    status VARCHAR(20) DEFAULT 'PENDING'
);

-- 4.3 ผลรางวัล (Results)
CREATE TABLE IF NOT EXISTS lotto_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    lotto_type_id UUID NOT NULL REFERENCES lotto_types(id),
    round_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    top_3 VARCHAR(10),
    bottom_2 VARCHAR(10),
    reward_data JSONB NOT NULL, -- เก็บรายละเอียดรางวัลอื่นๆ
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT unique_result_per_round UNIQUE (lotto_type_id, round_date)
);

/* ==========================================================================
   ส่วนที่ 5: ตั้งค่า Supabase Realtime & Security Policies (RLS)
   ========================================================================== */

-- 5.1 เปิดใช้งาน Row Level Security (RLS)
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE number_risks ENABLE ROW LEVEL SECURITY;
ALTER TABLE lotto_types ENABLE ROW LEVEL SECURITY;

-- 5.2 สร้าง Policy สำหรับ Realtime (ให้ Anonymous อ่านได้เฉพาะที่จำเป็น)
-- หมายเหตุ: Backend ของเราจัดการ Auth เอง แต่ Supabase Realtime client ต้องการสิทธิ์อ่านระดับ Database

-- Users: ยอมให้ Frontend ฟัง event ยอดเงินเปลี่ยน (กรองด้วย ID ที่ Frontend ถืออยู่)
DROP POLICY IF EXISTS "Enable read for realtime users" ON users;
CREATE POLICY "Enable read for realtime users" ON users FOR SELECT USING (true);

-- Risks: ยอมให้ทุกคนอ่านเลขอั้นได้ (เพื่อแสดงผลหน้าเว็บ)
DROP POLICY IF EXISTS "Enable read for all risks" ON number_risks;
CREATE POLICY "Enable read for all risks" ON number_risks FOR SELECT USING (true);

-- Lotto Types: ยอมให้ทุกคนอ่านสถานะหวยได้ (เปิด/ปิด)
DROP POLICY IF EXISTS "Enable read for all lottos" ON lotto_types;
CREATE POLICY "Enable read for all lottos" ON lotto_types FOR SELECT USING (true);

-- 5.3 เปิดใช้งาน Realtime Publication
-- เพิ่มตารางที่ต้องการให้ Frontend ฟัง event ได้
ALTER PUBLICATION supabase_realtime ADD TABLE users;
ALTER PUBLICATION supabase_realtime ADD TABLE number_risks;
ALTER PUBLICATION supabase_realtime ADD TABLE lotto_types;

-- เพิ่ม % ค่าคอม ในตารางผู้ใช้งาน (สมาชิก)
ALTER TABLE users ADD COLUMN commission_percent DECIMAL(5, 2) DEFAULT 0.00;

-- เพิ่มยอดค่าคอมมิชชั่น (บาท) ในตารางบิล
ALTER TABLE tickets ADD COLUMN commission_amount DECIMAL(15, 2) DEFAULT 0.00;

-- เพิ่มยอดถูกรางวัลของบิล (บาท) ในตารางบิล
ALTER TABLE tickets ADD COLUMN winning_amount NUMERIC(10, 2) DEFAULT 0;

ALTER TABLE shops ADD COLUMN line_id VARCHAR;

ALTER TABLE shops ALTER COLUMN login_config SET DEFAULT '{
  "background_url": "",
  "background_overlay": 0.3,
  "box_position": {"x": 50, "y": 50},
  "box_style": {
    "is_glassmorphism": true,
    "width": 40,
    "height": 50,
    "border_radius": 24,
    "border_width": 2,
    "border_color": "#ffd700",
    "shadow_x": 0,
    "shadow_y": 20,
    "shadow_blur": 50,
    "shadow_color": "#00000080",
    "box_bg_opacity": 0.1,
    "box_bg_blur": 20,
    "box_background_url": ""
  },
  "hero_login": {
    "Hero": "", 
    "is_visible": True,
    "Hero_position": {"x": 50, "y": 50},
    "config": { 
      "width": 40,
      "height": 50
    }
  },
  "results_section": {
    "is_visible": True,
    "results_style": "glass",
    "title": "ผลรางวัลล่าสุด",
    "display_limit": 10,
    "theme": "glass"
  },
  "payout_config": {
    "is_visible": True,
    "payout_style": "cascade",
    "position": {"x": 20, "y": 65}, 
    "config": {"width": 25, "height": "auto"},
    "rates": {
      "top3": 900,
      "tod3": 120,
      "top2": 90,
      "bottom2": 90,
      "run_top": 3.2,
      "run_bottom": 4.2
    }
  },
}'::jsonb;

ALTER TABLE shops ADD COLUMN brand_config JSONB DEFAULT '{
  "font_family": "Kanit",
  "fill_type": "color",
  "name_colors": ["#f3f4f6", "#ca8a04"],
  "texture_url": "",
  "text_shadow": "0px 2px 1px #996515, 0px 10px 15px rgba(0,0,0,0.5)",
  "text_stroke": "none",
  "logo_type": "image",
  "logo_emoji": "👑"
}'::jsonb;
