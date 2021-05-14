import base64
import collections
import json
import sys
import threading
import traceback
from urllib.parse import urlencode
import math

import requests
import tornado.gen
import tornado.web

import secret.achievements.utils
from common import generalUtils
from common.constants import gameModes
from common.constants import mods
from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from constants import rankedStatuses
from constants.exceptions import ppCalcException
from helpers import aeshelper
from helpers import replayHelper
from helpers import replayHelperRelax
from helpers import replayHelperAuto
from helpers import leaderboardHelper
from helpers import leaderboardHelperRelax
from helpers import leaderboardHelperAuto
from helpers.generalHelper import zingonify, getHackByFlag
from objects import beatmap
from objects import glob
from objects import score
from objects import scoreboard
from objects import scoreRelax
from objects import scoreboardRelax
from objects import scoreAuto
from objects import scoreboardAuto
from objects.charts import BeatmapChart, OverallChart
from secret import butterCake
from secret.discord_hooks import Webhook
MODULE_NAME = "submit_modular"

# Compile time constants are kinda cool.
DEF verified_badge = 1005

cpdef bint check_verified(user_id: int):
	"""Checks if the user with the id of `user_id` has the verified badge.
	
	Args:
		user_id (int): The ID of the user within the database to check for the
			presence of the verified badge.
	
	Returns:
		`bint` (bool) corresponding to whether the user has the verified badge.
	"""

	res = glob.db.fetch(
		"SELECT 1 FROM user_badges WHERE user = %s AND badge = %s LIMIT 1",
		(user_id, verified_badge)
	)

	return res is not None

class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-submit-modular.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	#@sentry.captureTornado
	def asyncPost(self):
		newCharts = self.request.uri == "/web/osu-submit-modular-selector.php"
		try:
			# Resend the score in case of unhandled exceptions
			keepSending = True

			# Get request ip
			ip = self.getRequestIP()

			# Print arguments
			if glob.debug:
				requestsManager.printArguments(self)

			# TODO: Maintenance check

			# Get parameters and IP
			scoreDataEnc = self.get_argument("score")
			iv = self.get_argument("iv")
			password = self.get_argument("pass")
			ip = self.getRequestIP()
			if glob.conf.extra["lets"]["submit"]["ignore-x-flag"]:
				quit_ = 0
			else:
				quit_ = self.get_argument("x") == "1"
			try:
				failTime = max(0, int(self.get_argument("ft", 0)))
			except ValueError:
				raise exceptions.invalidArgumentsException(MODULE_NAME)
			failed = not quit_ and failTime > 0

			# Get bmk and bml (notepad hack check)
			if "bmk" in self.request.arguments and "bml" in self.request.arguments:
				bmk = self.get_argument("bmk")
				bml = self.get_argument("bml")
			else:
				bmk = None
				bml = None

			# Get right AES Key
			if "osuver" in self.request.arguments:
				aeskey = "osu!-scoreburgr---------{}".format(self.get_argument("osuver"))
				OsuVer = self.get_argument("osuver")
			else:
				aeskey = "h89f2-890h2h89b34g-h80g134n90133"
				OsuVer = "Really Old"

			# Check arguments
			if glob.conf.extra["lets"]["submit"]["ignore-x-flag"] or "RC" in OsuVer:
				if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "st", "pass"]):
					raise exceptions.invalidArgumentsException(MODULE_NAME)
			else:
				if not requestsManager.checkArguments(self.request.arguments, ["score", "iv", "pass", "st", "x"]):
					raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get score data
			log.debug("Decrypting score data...")
			scoreData = aeshelper.decryptRinjdael(aeskey, iv, scoreDataEnc, True).split(":")
			if len(scoreData) < 16 or len(scoreData[0]) != 32:
				return
			username = scoreData[1].strip()

			# Login and ban check
			userID = userUtils.getID(username)
			# User exists check
			if userID == 0:
				raise exceptions.loginFailedException(MODULE_NAME, userID)
				
			 # Score submission lock check
			lock_key = "lets:score_submission_lock:{}:{}:{}".format(userID, scoreData[0], int(scoreData[9]))
			if glob.redis.get(lock_key) is not None:
				# The same score score is being submitted and it's taking a lot
				log.warning("Score submission blocked because there's a submission lock in place ({})".format(lock_key))
				return
 
			# Set score submission lock
			log.debug("Setting score submission lock {}".format(lock_key))
			glob.redis.set(lock_key, "1", 120)
 
				
			# Bancho session/username-pass combo check
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			# 2FA Check
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, userID, ip)
			# Generic bancho session check
			#if not userUtils.checkBanchoSession(userID):
				# TODO: Ban (see except exceptions.noBanchoSessionException block)
			#	raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)
			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)
			# Data length check
			if len(scoreData) < 16:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get restricted
			restricted = userUtils.isRestricted(userID)

			# Get variables for relax
			used_mods = int(scoreData[13])
			UsingRelax = used_mods & 128
			UsingAutopilot = used_mods & 8192

			if UsingRelax:
				DAGAyMode = "RELAX"
				ProfAppend = "rx/"
				rx_type = 1
			elif UsingAutopilot:
				DAGAyMode = "AUTOPILOT"
				ProfAppend = "ap/"
				rx_type = 2
			else:
				DAGAyMode = "VANILLA"
				ProfAppend = ""
				rx_type = 0

			# Create score object and set its data
			if UsingRelax:
				log.info("[RELAX] {} has submitted a score on {}...".format(username, scoreData[0]))
				s = scoreRelax.score()
			elif UsingAutopilot:
				log.info("[AUTOPILOT] {} has submitted a score on {}...".format(username, scoreData[0]))
				s = scoreAuto.score()
			else:
				log.info("[VANILLA] {} has submitted a score on {}...".format(username, scoreData[0]))
				s = score.score()

			s.setDataFromScoreData(scoreData, quit_=quit_, failed=failed)
			s.playerUserID = userID

			if s.completed == -1:
				# Duplicated score
				log.warning("Duplicated score detected, this is normal right after restarting the server")
				return

			# Set score stuff missing in score data
			s.playerUserID = userID

			# Get beatmap info
			beatmapInfo = beatmap.beatmap()
			beatmapInfo.setDataFromDB(s.fileMd5)

			# Make sure the beatmap is submitted and updated
			#if beatmapInfo.rankedStatus == rankedStatuses.NOT_SUBMITTED or beatmapInfo.rankedStatus == rankedStatuses.NEED_UPDATE or beatmapInfo.rankedStatus == rankedStatuses.UNKNOWN:
			#	log.debug("Beatmap is not submitted/outdated/unknown. Score submission aborted.")
			#	return

			# Check if the ranked status is allowed
			if beatmapInfo.rankedStatus not in glob.conf.extra["_allowed_beatmap_rank"]:
				log.debug("Beatmap's rankstatus is not allowed to be submitted. Score submission aborted.")
				return

			# Set play time and full play time
			s.fullPlayTime = beatmapInfo.hitLength
			if quit_ or failed:
				s.playTime = failTime // 1000

			# Calculate PP
			length = 0
			if s.passed and beatmapInfo.beatmapID < 100000000:
				length = beatmapInfo.hitLength
			else:
				length = failTime
			if UsingRelax: 	
				userUtils.incrementPlaytimeRX(userID, s.gameMode, length)
			elif UsingAutopilot:
				userUtils.incrementPlaytimeAP(userID, s.gameMode, length)
			else:
				userUtils.incrementPlaytime(userID, s.gameMode, length)
			midPPCalcException = None
			try:
				s.calculatePP()
			except Exception as e:
				# Intercept ALL exceptions and bypass them.
				# We want to save scores even in case PP calc fails
				# due to some rippoppai bugs.
				# I know this is bad, but who cares since I'll rewrite
				# the scores server again.
				log.error("Caught an exception in pp calculation, re-raising after saving score in db")
				s.pp = 0
				midPPCalcException = e

			# Restrict obvious cheaters
			if (not restricted) and not check_verified(userID):
				rx_pp = glob.conf.extra["lets"]["submit"]["max-rx-pp"]
				ap_pp = glob.conf.extra["lets"]["submit"]["max-ap-pp"]
				oof_pp = glob.conf.extra["lets"]["submit"]["max-vanilla-pp"]
				
				if UsingRelax and s.pp >= rx_pp and s.gameMode == gameModes.STD: 
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to breaking the PP cap on relax ({}pp)".format(s.pp))
					log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")
				elif UsingAutopilot and s.pp >= ap_pp and s.gameMode == gameModes.STD:
					userUtils.restrict(userID)
					userUtils.appendNotes(userID, "Restricted due to breaking the PP cap on autopilot ({}pp)".format(s.pp))
					log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")
				else:
					if s.pp >= oof_pp and s.gameMode == gameModes.STD:
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to breaking the PP cap on vanilla ({}pp)".format(s.pp))
						log.warning("**{}** ({}) has been restricted due to too high pp gain **({}pp)**".format(username, userID, s.pp), "cm")

			# Check notepad hack
			if bmk is None and bml is None:
				# No bmk and bml params passed, edited or super old client
				#log.warning("{} ({}) most likely submitted a score from an edited client or a super old client".format(username, userID), "cm")
				pass
			elif bmk != bml and not restricted:
				# bmk and bml passed and they are different, restrict the user
				userUtils.restrict(userID)
				userUtils.appendNotes(userID, "Restricted due to notepad hack")
				log.warning("**{}** ({}) has been restricted due to notepad hack".format(username, userID), "cm")
				return
			
			# Right before submitting the score, get the personal best score object (we need it for charts)
			if s.passed and s.oldPersonalBest > 0:
				if UsingRelax:
					oldPersonalBestRank = glob.personalBestCacheRX.get(userID, s.fileMd5)
				elif UsingAutopilot:
					oldPersonalBestRank = glob.personalBestCacheAP.get(userID, s.fileMd5)
				else:
					oldPersonalBestRank = glob.personalBestCache.get(userID, s.fileMd5)
				if oldPersonalBestRank == 0:
					# oldPersonalBestRank not found in cache, get it from db through a scoreboard object
					if UsingRelax:
						oldScoreboard = scoreboardRelax.scoreboardRelax(username, s.gameMode, beatmapInfo, False)
					elif UsingAutopilot:
						oldScoreboard = scoreboardAuto.scoreboardAuto(username, s.gameMode, beatmapInfo, False)
					else:
						oldScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)
					oldScoreboard.setPersonalBestRank()
					oldPersonalBestRank = max(oldScoreboard.personalBestRank, 0)
				if UsingRelax:
					oldPersonalBest = scoreRelax.score(s.oldPersonalBest, oldPersonalBestRank)
				elif UsingAutopilot:
					oldPersonalBest = scoreAuto.score(s.oldPersonalBest, oldPersonalBestRank)
				else:
					oldPersonalBest = score.score(s.oldPersonalBest, oldPersonalBestRank)
			else:
				oldPersonalBestRank = 0
				oldPersonalBest = None
			
			# Save score in db
			s.saveScoreInDB()
				
			# Remove lock as we have the score in the database at this point
			# and we can perform duplicates check through MySQL
			log.debug("Resetting score lock key {}".format(lock_key))
			glob.redis.delete(lock_key)
			
			# Client anti-cheat flags
			if not restricted and glob.conf.extra["mode"]["anticheat"]:
				haxFlags = scoreData[17].count(' ') # 4 is normal, 0 is irregular but inconsistent.
				if haxFlags != 4 and haxFlags != 0 and s.passed:
					hack = getHackByFlag(int(haxFlags))
					if type(hack) is str:
						# THOT DETECTED
						if glob.conf.config["discord"]["enable"]:
							webhook = Webhook(glob.conf.config["discord"]["ahook"],
											  color=0xadd836,
											  footer="I SPOT A THOT. [ Client AC ]")
							webhook.set_title(title=f"Caught some cheater {username} ({userID})")
							webhook.set_desc(f'This body caught with flag {haxFlags}\nIn enuming: {hack}')
							webhook.post()

			'''
			ignoreFlags = 4
			if glob.debug:
				# ignore multiple client flags if we are in debug mode
				ignoreFlags |= 8
			haxFlags = (len(scoreData[17])-len(scoreData[17].strip())) & ~ignoreFlags
			if haxFlags != 0 and not restricted:
				userHelper.restrict(userID)
				userHelper.appendNotes(userID, "-- Restricted due to clientside anti cheat flag ({}) (cheated score id: {})".format(haxFlags, s.scoreID))
				log.warning("**{}** ({}) has been restricted due clientside anti cheat flag **({})**".format(username, userID, haxFlags), "cm")
			'''

			# Hello, I'm Te Exx's fire. (google translate)
			if s.score < 0 or s.score > (2 ** 63) - 1 and glob.conf.extra["mode"]["anticheat"]:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to negative score (score submitter)")
			elif s.score < 0 or s.score > (2 ** 63) - 1 and not glob.conf.extra["mode"]["anticheat"]:
				alert = "{}, seems like you've exceed the score limit (INT32) or your score is negative, this score won't submit for you.".format(username.encode().decode("ASCII", "ignore"))
				params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": username.encode().decode("ASCII", "ignore"), "msg": alert})
				requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
				return

			# Make sure the score is not memed
			if s.gameMode == gameModes.MANIA and s.score > 1000000:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Banned due to mania score > 1000000 (score submitter)")
			elif s.gameMode == gameModes.MANIA and s.score > 1000000 and not glob.conf.extra["mode"]["anticheat"]:
				alert = "{}, seems like you've exceed osu!Mania score limit (1000000), this score won't submit for you.".format(username.encode().decode("ASCII", "ignore"))
				params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": username.encode().decode("ASCII", "ignore"), "msg": alert})
				requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
				return

			# google translate : I put my face on it, I put my head on it and I put my heart o
			if ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
			or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0)\
			or ((s.mods & mods.RELAX) > 0 and (s.mods & mods.RELAX2) > 0) \
			or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0) \
			and glob.conf.extra["mode"]["anticheat"]:
				userUtils.ban(userID)
				userUtils.appendNotes(userID, "Impossible mod combination {} (score submitter)".format(s.mods))
			elif ((s.mods & mods.DOUBLETIME) > 0 and (s.mods & mods.HALFTIME) > 0) \
			or ((s.mods & mods.HARDROCK) > 0 and (s.mods & mods.EASY) > 0)\
			or ((s.mods & mods.RELAX) > 0 and (s.mods & mods.RELAX2) > 0) \
			or ((s.mods & mods.SUDDENDEATH) > 0 and (s.mods & mods.NOFAIL) > 0) \
			and not glob.conf.extra["mode"]["anticheat"]:
				alert = "{}, seems like you've used osu! score submitter limit (Impossible mod combination), this score won't submit for you.".format(username.encode().decode("ASCII", "ignore"))
				params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": username.encode().decode("ASCII", "ignore"), "msg": alert})
				requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))
				return

			# NOTE: Process logging was removed from the client starting from 20180322
			if s.completed == 3 and "pl" in self.request.arguments:
				butterCake.bake(self, s)
				
			# Save replay for all passed scores
			# Make sure the score has an id as well (duplicated?, query error?)
			if s.passed and s.scoreID > 0 and s.completed == 3:
				if "score" in self.request.files:
					# Save the replay if it was provided
					log.debug("Saving replay ({})...".format(s.scoreID))
					replay = self.request.files["score"][0]["body"]

					if UsingRelax:
						RPBUILD = replayHelperRelax.buildFullReplay
						with open("{}_relax/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], (s.scoreID)), "wb") as f:
							f.write(replay)
					elif UsingAutopilot:
						RPBUILD = replayHelperAuto.buildFullReplay
						with open("{}_ap/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], (s.scoreID)), "wb") as f:
							f.write(replay)
					else:
						RPBUILD = replayHelper.buildFullReplay
						with open("{}/replay_{}.osr".format(glob.conf.config["server"]["replayspath"], (s.scoreID)), "wb") as f:
							f.write(replay)

					if glob.conf.config["cono"]["enable"]:
						# We run this in a separate thread to avoid slowing down scores submission,
						# as cono needs a full replay
						threading.Thread(target=lambda: glob.redis.publish(
							"cono:analyze", json.dumps({
								"score_id": s.scoreID,
								"beatmap_id": beatmapInfo.beatmapID,
								"user_id": s.playerUserID,
								"game_mode": s.gameMode,
								"pp": s.pp,
								"completed": s.completed,
								"replay_data": base64.b64encode(
									RPBUILD(
										s.scoreID,
										rawReplay=self.request.files["score"][0]["body"]
									)
								).decode(),
							})
						)).start()
				else:
					# Restrict if no replay was provided
					if not restricted:
						userUtils.restrict(userID)
						userUtils.appendNotes(userID, "Restricted due to missing replay while submitting a score.")
						log.warning("**{}** ({}) has been restricted due to not submitting a replay on map {}.".format(
							username, userID, s.fileMd5
						), "cm")

			# Update beatmap playcount (and passcount)
			beatmap.incrementPlaycount(s.fileMd5, s.passed)

			# Let the api know of this score
			if s.scoreID:
				glob.redis.publish("api:score_submission", s.scoreID)

			# Re-raise pp calc exception after saving score, cake, replay etc
			# so Sentry can track it without breaking score submission
			if midPPCalcException is not None:
				raise ppCalcException(midPPCalcException)

			# Always update users stats (total/ranked score, playcount, level, acc and pp)
			# even if not passed
			log.debug("Updating {}'s stats...".format(username))
			# Update personal beatmaps playcount
			userUtils.incrementUserBeatmapPlaycount(userID, s.gameMode, beatmapInfo.beatmapID)
			if UsingRelax:
				userUtils.updateStatsRx(userID, s)
				userUtils.updateTotalHitsRX(score=s)
			elif UsingAutopilot:
				userUtils.updateStatsAP(userID, s)
				userUtils.updateTotalHitsAP(score=s)
			else:
				userUtils.updateStats(userID, s)
				userUtils.updateTotalHits(score=s)
			
			# Get "after" stats for ranking panel
			# and to determine if we should update the leaderboard
			# (only if we passed that song)
			if s.passed:
				# Get new stats
				if UsingRelax:
					oldUserStats = glob.userStatsCacheRX.get(userID, s.gameMode)
					oldRank = userUtils.getGameRankRx(userID, s.gameMode)
					newUserStats = userUtils.getUserStatsRx(userID, s.gameMode)
					glob.userStatsCacheRX.update(userID, s.gameMode, newUserStats)
					leaderboardHelperRelax.update(userID, newUserStats["pp"], s.gameMode)
					maxCombo = userUtils.getMaxComboRX(userID, s.gameMode)
				elif UsingAutopilot:
					oldUserStats = glob.userStatsCacheAP.get(userID, s.gameMode)
					oldRank = userUtils.getGameRankAP(userID, s.gameMode)
					newUserStats = userUtils.getUserStatsAP(userID, s.gameMode)
					glob.userStatsCacheAP.update(userID, s.gameMode, newUserStats)
					leaderboardHelperAuto.update(userID, newUserStats["pp"], s.gameMode)
					maxCombo = userUtils.getMaxComboAP(userID, s.gameMode)
				else:
					oldUserStats = glob.userStatsCache.get(userID, s.gameMode)
					oldRank = userUtils.getGameRank(userID, s.gameMode)
					newUserStats = userUtils.getUserStats(userID, s.gameMode)
					glob.userStatsCache.update(userID, s.gameMode, newUserStats)
					leaderboardHelper.update(userID, newUserStats["pp"], s.gameMode)
					maxCombo = userUtils.getMaxCombo(userID, s.gameMode)

				# Update leaderboard (global and country) if score/pp has changed
				if s.completed == 3 and newUserStats["pp"] != oldUserStats["pp"]:
					if UsingRelax:
						leaderboardHelperRelax.update(userID, newUserStats["pp"], s.gameMode)
						leaderboardHelperRelax.updateCountry(userID, newUserStats["pp"], s.gameMode)
					elif UsingAutopilot:
						leaderboardHelperAuto.update(userID, newUserStats["pp"], s.gameMode)
						leaderboardHelperAuto.updateCountry(userID, newUserStats["pp"], s.gameMode)
					else:
						leaderboardHelper.update(userID, newUserStats["pp"], s.gameMode)
						leaderboardHelper.updateCountry(userID, newUserStats["pp"], s.gameMode)

			# TODO: Update max combo
			
			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# IP log
			userUtils.IPLog(userID, ip)

			# Score submission and stats update done
			log.debug("Score submission and user stats update done!")
			oldStats = userUtils.getUserStats(userID, s.gameMode)

			# Score has been submitted, do not retry sending the score if
			# there are exceptions while building the ranking panel
			keepSending = False

			# At the end, check achievements
			if s.passed:
				new_achievements = secret.achievements.utils.unlock_achievements(s, beatmapInfo, newUserStats)

			# Output ranking panel only if we passed the song
			# and we got valid beatmap info from db
			if beatmapInfo is not None and beatmapInfo != False and s.passed:
				log.debug("Started building ranking panel")

				# Trigger bancho stats cache update
				glob.redis.publish("peppy:update_cached_stats", userID)

				# Get personal best after submitting the score
				if UsingRelax:
					newScoreboard = scoreboardRelax.scoreboardRelax(username, s.gameMode, beatmapInfo, False)
				elif UsingAutopilot:
					newScoreboard = scoreboardAuto.scoreboardAuto(username, s.gameMode, beatmapInfo, False)
				else:
					newScoreboard = scoreboard.scoreboard(username, s.gameMode, beatmapInfo, False)

				newScoreboard.setPersonalBestRank()
				personalBestID = newScoreboard.getPersonalBest()
				assert personalBestID is not None
				# Get rank info (current rank, pp/score to next rank, user who is 1 rank above us)
				if UsingRelax:
					rankInfo = leaderboardHelperRelax.getRankInfo(userID, s.gameMode)
					currentPersonalBest = scoreRelax.score(personalBestID, newScoreboard.personalBestRank)
				if UsingAutopilot:
					rankInfo = leaderboardHelperAuto.getRankInfo(userID, s.gameMode)
					currentPersonalBest = scoreAuto.score(personalBestID, newScoreboard.personalBestRank)
				else:
					rankInfo = leaderboardHelper.getRankInfo(userID, s.gameMode)
					currentPersonalBest = score.score(personalBestID, newScoreboard.personalBestRank)

				# Output dictionary
				if newCharts:
					log.debug("Using new charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount + 1),
							("beatmapPasscount", beatmapInfo.passcount + (s.completed == 3)),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						BeatmapChart(
							oldPersonalBest if s.completed == 3 else currentPersonalBest,
							currentPersonalBest if s.completed == 3 else s,
							beatmapInfo.beatmapID,
						),
						OverallChart(
							userID, oldUserStats, newUserStats, s, new_achievements, oldRank, rankInfo["currentRank"]
						)
					]
				else:
					log.debug("Using old charts")
					dicts = [
						collections.OrderedDict([
							("beatmapId", beatmapInfo.beatmapID),
							("beatmapSetId", beatmapInfo.beatmapSetID),
							("beatmapPlaycount", beatmapInfo.playcount),
							("beatmapPasscount", beatmapInfo.passcount),
							("approvedDate", beatmapInfo.rankingDate)
						]),
						collections.OrderedDict([
							("chartId", "overall"),
							("chartName", "Overall Ranking"),
							("chartEndDate", ""),
							("beatmapRankingBefore", oldPersonalBestRank),
							("beatmapRankingAfter", newScoreboard.personalBestRank),
							("rankedScoreBefore", oldUserStats["rankedScore"]),
							("rankedScoreAfter", newUserStats["rankedScore"]),
							("totalScoreBefore", oldUserStats["totalScore"]),
							("totalScoreAfter", newUserStats["totalScore"]),
							("playCountBefore", newUserStats["playcount"]),
							("accuracyBefore", float(oldUserStats["accuracy"])/100),
							("accuracyAfter", float(newUserStats["accuracy"])/100),
							("rankBefore", oldRank),
							("rankAfter", rankInfo["currentRank"]),
							("toNextRank", rankInfo["difference"]),
							("toNextRankUser", rankInfo["nextUsername"]),
							("achievements", ""),
							("achievements-new", secret.achievements.utils.achievements_response(new_achievements)),
							("onlineScoreId", s.scoreID)
						])
					]
				output = "\n".join(zingonify(x) for x in dicts)

				# Some debug messages
				log.debug("Generated output for online ranking screen!")
				log.debug(output)

				# How many PP you got and did you gain any ranks?
				ppGained = newUserStats["pp"] - oldUserStats["pp"]
				gainedRanks = oldRank - rankInfo["currentRank"]

				# Get info about score if they passed the map (Ranked)
				userStats = userUtils.getUserStats(userID, s.gameMode)
				if s.completed == 3 and not restricted and beatmapInfo.rankedStatus >= rankedStatuses.RANKED and s.pp > 0:
					glob.redis.publish("scores:new_score", json.dumps({
						"gm":s.gameMode,
						"user":{"username":username, "userID": userID, "rank":newUserStats["gameRank"],"oldaccuracy":oldStats["accuracy"],"accuracy":newUserStats["accuracy"], "oldpp":oldStats["pp"],"pp":newUserStats["pp"]},
						"score":{"scoreID": s.scoreID, "mods":s.mods, "accuracy":s.accuracy, "missess":s.cMiss, "combo":s.maxCombo, "pp":s.pp, "rank":newScoreboard.personalBestRank, "ranking":s.rank},
						"beatmap":{"beatmapID": beatmapInfo.beatmapID, "beatmapSetID": beatmapInfo.beatmapSetID, "max_combo":beatmapInfo.maxCombo, "song_name":beatmapInfo.songName}
						}))

				# Send message to #announce if we're rank #1
				if newScoreboard.personalBestRank == 1 and s.completed == 3 and not restricted:
					annmsg = "[{}] [{}/{}u/{} {}] achieved rank #1 on [https://ussr.pl/b/{} {}] ({})".format(
						DAGAyMode,
						glob.conf.config["server"]["serverurl"],
						ProfAppend,
						userID,
						username.encode().decode("ASCII", "ignore"),
						beatmapInfo.beatmapID,
						beatmapInfo.songName.encode().decode("ASCII", "ignore"),
						gameModes.getGamemodeFull(s.gameMode)
						)
								
					params = urlencode({"k": glob.conf.config["server"]["apikey"], "to": "#announce", "msg": annmsg})
					requests.get("{}/api/v1/fokabotMessage?{}".format(glob.conf.config["server"]["banchourl"], params))

					#first places go brrr haha
					glob.db.execute(f"DELETE FROM first_places WHERE beatmap_md5 = '{s.fileMd5}' AND mode = {s.gameMode} AND relax = {rx_type}")
					query = f"""
							INSERT INTO first_places
								(
									score_id,
									user_id,
									score,
									max_combo,
									full_combo,
									mods,
									300_count,
									100_count,
									50_count,
									miss_count,
									timestamp,
									mode,
									completed,
									accuracy,
									pp,
									play_time,
									beatmap_md5,
									relax
								)
							VALUES
								(
									{s.scoreID},
									{userID},
									{s.score},
									{s.maxCombo},
									{s.fullCombo},
									{s.mods},
									{s.c300},
									{s.c100},
									{s.c50},
									{s.cMiss},
									{s.playDateTime},
									{s.gameMode},
									{s.completed},
									{s.accuracy*100},
									{s.pp},
									{s.playTime if s.playTime is not None and not s.passed else s.fullPlayTime},
									'{s.fileMd5}',
									{rx_type}
								)
					"""
					log.debug(query)
					glob.db.execute(query)
					# Let's send them to Discord too, because we cool :sunglasses:
					
					#around wheer it dies
					if glob.conf.config["discord"]["enable"]:
						# First, let's check what mod does the play have
						ScoreMods = ""
						if s.mods == 0:
							ScoreMods += "NM"
						if s.mods & mods.NOFAIL > 0:
							ScoreMods += "NF"
						if s.mods & mods.EASY > 0:
							ScoreMods += "EZ"
						if s.mods & mods.HIDDEN > 0:
							ScoreMods += "HD"
						if s.mods & mods.HARDROCK > 0:
							ScoreMods += "HR"
						if s.mods & mods.DOUBLETIME > 0:
							ScoreMods += "DT"
						if s.mods & mods.HALFTIME > 0:
							ScoreMods += "HT"
						if s.mods & mods.FLASHLIGHT > 0:
							ScoreMods += "FL"
						if s.mods & mods.SPUNOUT > 0:
							ScoreMods += "SO"
						if s.mods & mods.TOUCHSCREEN > 0:
							ScoreMods += "TD"
						if s.mods & mods.RELAX > 0:
							ScoreMods += "RX"
						if s.mods & mods.RELAX2 > 0:
							ScoreMods += "AP"
						# Second, get the webhook link from config

						url = glob.conf.config["discord"]["score"]

						# Then post them!
						webhook = Webhook(url, color=0xadd8e6, footer="This score is submitted on RealistikOsu!")
						webhook.set_author(name=username.encode().decode("ASCII", "ignore"), icon='https://a.ussr.pl/{}'.format(userID))
						webhook.set_title(title=f"New score by {username}!")
						webhook.set_desc("[{}] Achieved #1 on mode **{}**, {} +{}!".format(DAGAyMode, gameModes.getGamemodeFull(s.gameMode), beatmapInfo.songName.encode().decode("ASCII", "ignore"), ScoreMods))
						webhook.add_field(name='Total: {}pp'.format(float("{0:.2f}".format(s.pp))), value='Gained: +{}pp'.format(float("{0:.2f}".format(ppGained))))
						webhook.add_field(name='Actual rank: {}'.format(rankInfo["currentRank"]), value='[Download Link](https://osu.gatari.pw/d/{})'.format(beatmapInfo.beatmapSetID))
						webhook.add_field(name='Played by: {}'.format(username.encode().decode("ASCII", "ignore")), value="[Go to user's profile](https://ussr.pl/{}u/{})".format(ProfAppend, userID))
						webhook.set_image('https://assets.ppy.sh/beatmaps/{}/covers/cover.jpg'.format(beatmapInfo.beatmapSetID))
						webhook.post()

				# Write message to client
				self.write(output)
			else:
				# No ranking panel, tell the osu client to stfu
				self.write("error: no")
			
			# Send username change request to bancho if needed
			# (key is deleted bancho-side)
			newUsername = glob.redis.get("ripple:change_username_pending:{}".format(userID))
			if newUsername is not None:
				log.debug("Sending username change request for user {} to Bancho".format(userID))
				glob.redis.publish("peppy:change_username", json.dumps({
					"userID": userID,
					"newUsername": newUsername.decode("utf-8")
				}))

			# Datadog stats
			glob.dog.increment(glob.DATADOG_PREFIX+".submitted_scores")
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass")
		except exceptions.need2FAException:
			# Send error pass to notify the user
			# resend the score at regular intervals
			# for users with memy connection
			self.set_status(408)
			self.write("error: 2fa")
		except exceptions.userBannedException:
			self.write("error: ban")
		except exceptions.noBanchoSessionException:
			# We don't have an active bancho session.
			# Don't ban the user but tell the client to send the score again.
			# Once we are sure that this error doesn't get triggered when it
			# shouldn't (eg: bancho restart), we'll ban users that submit
			# scores without an active bancho session.
			# We only log through schiavo atm (see exceptions.py).
			self.set_status(408)
			self.write("error: pass")
		except:
			# Try except block to avoid more errors
			try:
				log.error("Unknown error in {}!\n```{}\n{}```".format(MODULE_NAME, sys.exc_info(), traceback.format_exc()))
				if glob.sentry:
					yield tornado.gen.Task(self.captureException, exc_info=True)
			except:
				pass

			# Every other exception returns a 408 error (timeout)
			# This avoids lost scores due to score server crash
			# because the client will send the score again after some time.
			if keepSending:
				self.set_status(408)
