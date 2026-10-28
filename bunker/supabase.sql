-- BUNKER multiplayer schema. Safe to run alongside existing app tables.
create extension if not exists pgcrypto;

create table if not exists public.bunker_rooms(
 id uuid primary key default gen_random_uuid(), code text unique not null,
 host_id uuid not null references auth.users(id) on delete cascade,
 status text not null default 'lobby' check(status in('lobby','playing','voting','finished')),
 max_players int not null default 8 check(max_players between 3 and 8),
 bunker_spots int not null default 3 check(bunker_spots between 1 and 7),
 spectators_enabled boolean not null default true, custom_catastrophe text, catastrophe text,
 current_event text, round int not null default 0, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create table if not exists public.bunker_players(
 id uuid primary key default gen_random_uuid(), room_id uuid not null references public.bunker_rooms(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 display_name text not null check(char_length(display_name) between 1 and 24),
 is_spectator boolean not null default false, alive boolean not null default true,
 revealed boolean not null default false, character jsonb not null default '{}'::jsonb,
 joined_at timestamptz not null default now(), unique(room_id,user_id)
);
create table if not exists public.bunker_votes(
 room_id uuid not null references public.bunker_rooms(id) on delete cascade,
 round int not null, voter_id uuid not null references auth.users(id) on delete cascade,
 target_id uuid not null references public.bunker_players(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(room_id,round,voter_id)
);
create index if not exists bunker_players_room_idx on public.bunker_players(room_id);
create index if not exists bunker_votes_round_idx on public.bunker_votes(room_id,round);
alter table public.bunker_rooms enable row level security;
alter table public.bunker_players enable row level security;
alter table public.bunker_votes enable row level security;
drop policy if exists bunker_room_member_read on public.bunker_rooms;
create policy bunker_room_member_read on public.bunker_rooms for select to authenticated using(
 host_id=(select auth.uid()) or exists(select 1 from public.bunker_players p where p.room_id=bunker_rooms.id and p.user_id=(select auth.uid()))
);
revoke all on public.bunker_rooms,public.bunker_players,public.bunker_votes from anon,authenticated;
grant select on public.bunker_rooms to authenticated;

create or replace function public.bunker_create_room(p_name text,p_max_players int default 8,p_bunker_spots int default 3,p_spectators_enabled boolean default true,p_custom_catastrophe text default null)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; c text; n text:=left(trim(coalesce(p_name,'')),24);
begin
 if u is null then raise exception 'AUTH_REQUIRED'; end if;
 if n='' then raise exception 'NAME_REQUIRED'; end if;
 if p_max_players not between 3 and 8 then raise exception 'MAX_PLAYERS_MUST_BE_3_TO_8'; end if;
 if p_bunker_spots<1 or p_bunker_spots>=p_max_players then raise exception 'INVALID_BUNKER_SPOTS'; end if;
 loop c:=upper(substr(encode(gen_random_bytes(5),'hex'),1,6)); exit when not exists(select 1 from public.bunker_rooms where code=c); end loop;
 insert into public.bunker_rooms(code,host_id,max_players,bunker_spots,spectators_enabled,custom_catastrophe)
 values(c,u,p_max_players,p_bunker_spots,coalesce(p_spectators_enabled,true),nullif(left(trim(coalesce(p_custom_catastrophe,'')),160),'')) returning * into r;
 insert into public.bunker_players(room_id,user_id,display_name) values(r.id,u,n);
 return jsonb_build_object('code',r.code,'room_id',r.id);
end $$;

create or replace function public.bunker_join_room(p_code text,p_name text,p_spectator boolean default false)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; n text:=left(trim(coalesce(p_name,'')),24); cnt int;
begin
 if u is null then raise exception 'AUTH_REQUIRED'; end if;
 if n='' then raise exception 'NAME_REQUIRED'; end if;
 select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 if r.status<>'lobby' then raise exception 'GAME_ALREADY_STARTED'; end if;
 if p_spectator and not r.spectators_enabled then raise exception 'SPECTATORS_DISABLED'; end if;
 if not p_spectator then select count(*) into cnt from public.bunker_players where room_id=r.id and not is_spectator; if cnt>=r.max_players then raise exception 'ROOM_FULL'; end if; end if;
 insert into public.bunker_players(room_id,user_id,display_name,is_spectator) values(r.id,u,n,coalesce(p_spectator,false))
 on conflict(room_id,user_id) do update set display_name=excluded.display_name,is_spectator=excluded.is_spectator;
 return jsonb_build_object('code',r.code,'room_id',r.id);
end $$;

create or replace function public.bunker_get_state(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; me public.bunker_players%rowtype; ps jsonb; votes jsonb;
begin
 select x.* into r from public.bunker_rooms x where x.code=upper(trim(coalesce(p_code,''))) and exists(select 1 from public.bunker_players p where p.room_id=x.id and p.user_id=u);
 if not found then raise exception 'ROOM_NOT_FOUND_OR_NOT_MEMBER'; end if;
 select * into me from public.bunker_players where room_id=r.id and user_id=u;
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.display_name,'is_spectator',p.is_spectator,'alive',p.alive,'revealed',p.revealed,'is_me',p.user_id=u,'is_host',p.user_id=r.host_id,
 'character',case when p.user_id=u or p.revealed or r.status='finished' then p.character else null end,
 'votes',case when r.status in('voting','finished') then (select count(*) from public.bunker_votes v where v.room_id=r.id and v.round=r.round and v.target_id=p.id) else 0 end) order by p.joined_at),'[]'::jsonb)
 into ps from public.bunker_players p where p.room_id=r.id;
 select coalesce(jsonb_agg(jsonb_build_object('target_id',target_id)),'[]'::jsonb) into votes from public.bunker_votes where room_id=r.id and round=r.round and voter_id=u;
 return jsonb_build_object('room',jsonb_build_object('code',r.code,'status',r.status,'host_id',r.host_id,'is_host',r.host_id=u,'max_players',r.max_players,'bunker_spots',r.bunker_spots,'spectators_enabled',r.spectators_enabled,'catastrophe',r.catastrophe,'custom_catastrophe',r.custom_catastrophe,'current_event',r.current_event,'round',r.round),
 'me',jsonb_build_object('id',me.id,'name',me.display_name,'is_spectator',me.is_spectator,'alive',me.alive),'players',ps,'my_votes',votes);
end $$;

create or replace function public.bunker_start_game(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; cnt int; p record;
 jobs text[]:=array['Врач','Инженер-ядерщик','Психолог','Пилот','Агроном','Химик','Спасатель','Учитель','Механик','Ветеринар','Программист','Геолог','Повар','Военный связист','Микробиолог','Электрик'];
 healths text[]:=array['Отличное здоровье','Астма','Слабый иммунитет','Перелом руки','Аллергия на пенициллин','Хроническая мигрень','Устойчивость к радиации','Бессонница'];
 hobbies text[]:=array['Выращивание растений','Ремонт техники','Первая помощь','Ориентирование','Кулинария','Радиотехника','Плавание','Изучение языков','Рукоделие','Наблюдение за звёздами'];
 phobias text[]:=array['Клаустрофобия','Боязнь крови','Арахнофобия','Акрофобия','Нет выраженных фобий','Боязнь темноты'];
 catastrophes text[]:=array['Ядерная зима: поверхность заражена, температура падает.','Неизвестный вирус разрушил систему здравоохранения.','Астероид уничтожил инфраструктуру планеты.','Глобальный блэкаут отключил энергосистемы.','Сверхизвержение заполнило атмосферу пеплом.','Автономные системы вышли из-под контроля.'];
begin
 select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found or r.host_id<>u then raise exception 'HOST_ONLY'; end if;
 if r.status<>'lobby' then raise exception 'GAME_NOT_IN_LOBBY'; end if;
 select count(*) into cnt from public.bunker_players where room_id=r.id and not is_spectator;
 if cnt<3 then raise exception 'NEED_AT_LEAST_3_PLAYERS'; end if;
 update public.bunker_rooms set status='playing',round=1,catastrophe=coalesce(custom_catastrophe,catastrophes[1+floor(random()*array_length(catastrophes,1))::int]),current_event=null,updated_at=now() where id=r.id;
 for p in select id from public.bunker_players where room_id=r.id and not is_spectator loop
 update public.bunker_players set character=jsonb_build_object('profession',jobs[1+floor(random()*array_length(jobs,1))::int],'health',healths[1+floor(random()*array_length(healths,1))::int],'hobby',hobbies[1+floor(random()*array_length(hobbies,1))::int],'phobia',phobias[1+floor(random()*array_length(phobias,1))::int],
 'baggage',(array['Аптечка','Набор инструментов','Семена растений','Рация','Фильтр для воды','Полевой дневник','Запас батарей','Набор для ремонта'])[1+floor(random()*8)::int],
 'secret',(array['Скрывает важный навык','Знает устройство бункера','Имеет дополнительный запас еды','Секретов не обнаружено','Может починить вентиляцию'])[1+floor(random()*5)::int]),revealed=false,alive=true where id=p.id;
 end loop;
 return jsonb_build_object('ok',true,'round',1);
end $$;

create or replace function public.bunker_reveal_card(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype;
begin
 select x.* into r from public.bunker_rooms x join public.bunker_players p on p.room_id=x.id where x.code=upper(trim(coalesce(p_code,''))) and p.user_id=u and not p.is_spectator;
 if not found or r.status<>'playing' then raise exception 'NOT_ALLOWED_TO_REVEAL'; end if;
 update public.bunker_players set revealed=true where room_id=r.id and user_id=u and alive; return jsonb_build_object('ok',true);
end $$;

create or replace function public.bunker_open_vote(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype;
begin select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found or r.host_id<>u then raise exception 'HOST_ONLY'; end if; if r.status<>'playing' then raise exception 'GAME_NOT_IN_PLAYING'; end if;
 update public.bunker_rooms set status='voting',current_event=null,updated_at=now() where id=r.id; return jsonb_build_object('ok',true); end $$;

create or replace function public.bunker_cast_vote(p_code text,p_target_player_id uuid)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; me public.bunker_players%rowtype; target public.bunker_players%rowtype;
begin
 select x.* into r from public.bunker_rooms x join public.bunker_players p on p.room_id=x.id where x.code=upper(trim(coalesce(p_code,''))) and p.user_id=u for update of x;
 if not found or r.status<>'voting' then raise exception 'VOTING_NOT_OPEN'; end if;
 select * into me from public.bunker_players where room_id=r.id and user_id=u;
 select * into target from public.bunker_players where room_id=r.id and id=p_target_player_id;
 if me.is_spectator or not me.alive then raise exception 'NOT_ELIGIBLE_TO_VOTE'; end if;
 if not found or target.is_spectator or not target.alive or target.user_id=u then raise exception 'INVALID_TARGET'; end if;
 insert into public.bunker_votes(room_id,round,voter_id,target_id) values(r.id,r.round,u,target.id) on conflict(room_id,round,voter_id) do update set target_id=excluded.target_id,created_at=now();
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.bunker_resolve_vote(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; eliminated uuid; alive_count int; n text;
begin
 select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found or r.host_id<>u then raise exception 'HOST_ONLY'; end if; if r.status<>'voting' then raise exception 'VOTING_NOT_OPEN'; end if;
 select target_id into eliminated from public.bunker_votes where room_id=r.id and round=r.round group by target_id order by count(*) desc,random() limit 1;
 if eliminated is null then raise exception 'NO_VOTES_YET'; end if;
 update public.bunker_players set alive=false where id=eliminated;
 select display_name into n from public.bunker_players where id=eliminated;
 select count(*) into alive_count from public.bunker_players where room_id=r.id and not is_spectator and alive;
 if alive_count<=r.bunker_spots then update public.bunker_rooms set status='finished',current_event='Партия завершена. Оставшиеся игроки попали в бункер.',updated_at=now() where id=r.id;
 else update public.bunker_rooms set status='playing',round=round+1,current_event='Из бункера исключён игрок: '||n,updated_at=now() where id=r.id; end if;
 return jsonb_build_object('ok',true,'eliminated',n,'alive_remaining',alive_count);
end $$;

create or replace function public.bunker_trigger_event(p_code text)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; ev text;
begin
 select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found or r.host_id<>u then raise exception 'HOST_ONLY'; end if;
 if r.status not in('playing','voting') then raise exception 'GAME_NOT_ACTIVE'; end if;
 ev:=(array['Запас воды сократился. Кто распределит остатки?','Вентиляция нестабильна. Нужен план ремонта.','Обнаружен закрытый отсек неизвестного назначения.','Радиосигнал обещает помощь, но источник не подтверждён.','Запасы еды рассчитаны на меньшее число людей.','Система безопасности заблокировала коридор.'])[1+floor(random()*6)::int];
 update public.bunker_rooms set current_event=ev,updated_at=now() where id=r.id; return jsonb_build_object('ok',true,'event',ev);
end $$;

revoke all on function public.bunker_create_room(text,int,int,boolean,text) from public;
revoke all on function public.bunker_join_room(text,text,boolean) from public;
revoke all on function public.bunker_get_state(text) from public;
revoke all on function public.bunker_start_game(text) from public;
revoke all on function public.bunker_reveal_card(text) from public;
revoke all on function public.bunker_open_vote(text) from public;
revoke all on function public.bunker_cast_vote(text,uuid) from public;
revoke all on function public.bunker_resolve_vote(text) from public;
revoke all on function public.bunker_trigger_event(text) from public;
grant execute on function public.bunker_create_room(text,int,int,boolean,text) to authenticated;
grant execute on function public.bunker_join_room(text,text,boolean) to authenticated;
grant execute on function public.bunker_get_state(text) to authenticated;
grant execute on function public.bunker_start_game(text) to authenticated;
grant execute on function public.bunker_reveal_card(text) to authenticated;
grant execute on function public.bunker_open_vote(text) to authenticated;
grant execute on function public.bunker_cast_vote(text,uuid) to authenticated;
grant execute on function public.bunker_resolve_vote(text) to authenticated;
grant execute on function public.bunker_trigger_event(text) to authenticated;
