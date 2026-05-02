INSERT INTO mqtt_migration.topic_mapping (
    priority,
    source_table,
    rule_type,
    source_pattern,
    target_kind,
    notes
)
VALUES
    (10, 'public.mqtt_online', 'exact', 'shellies/BV.LR.SY/ProjectorScreen/online', 'skip', 'Ignored legacy ProjectorScreen online topic'),
    (10, 'public.mqtt_online', 'exact', 'shellies/living_room/shelly/switch/lw/online', 'skip', 'Ignored legacy living room switch online topic'),
    (10, 'public.mqtt_topics', 'exact', 'shellies/BV.LR.SY/ProjectorScreen/online', 'skip', 'Ignored retained legacy ProjectorScreen online topic'),
    (10, 'public.mqtt_topics', 'exact', 'shellies/living_room/shelly/switch/lw/online', 'skip', 'Ignored retained legacy living room switch online topic')
ON CONFLICT DO NOTHING;
