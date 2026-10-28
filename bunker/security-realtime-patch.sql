-- Run after supabase.sql if member room refresh / Realtime events do not work.
grant select on public.bunker_players to authenticated;
drop policy if exists bunker_player_self_read on public.bunker_players;
create policy bunker_player_self_read on public.bunker_players
for select to authenticated using (user_id = (select auth.uid()));

-- Let an already-joined player reopen an active room from its invitation link.
create or replace function public.bunker_join_room(p_code text,p_name text,p_spectator boolean default false)
returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare u uuid:=auth.uid(); r public.bunker_rooms%rowtype; n text:=left(trim(coalesce(p_name,'')),24); cnt int;
begin
 if u is null then raise exception 'AUTH_REQUIRED'; end if;
 if n='' then raise exception 'NAME_REQUIRED'; end if;
 select * into r from public.bunker_rooms where code=upper(trim(coalesce(p_code,''))) for update;
 if not found then raise exception 'ROOM_NOT_FOUND'; end if;
 if exists(select 1 from public.bunker_players where room_id=r.id and user_id=u) then
   return jsonb_build_object('code',r.code,'room_id',r.id);
 end if;
 if r.status<>'lobby' then raise exception 'GAME_ALREADY_STARTED'; end if;
 if p_spectator and not r.spectators_enabled then raise exception 'SPECTATORS_DISABLED'; end if;
 if not p_spectator then
   select count(*) into cnt from public.bunker_players where room_id=r.id and not is_spectator;
   if cnt>=r.max_players then raise exception 'ROOM_FULL'; end if;
 end if;
 insert into public.bunker_players(room_id,user_id,display_name,is_spectator) values(r.id,u,n,coalesce(p_spectator,false));
 return jsonb_build_object('code',r.code,'room_id',r.id);
end $$;
