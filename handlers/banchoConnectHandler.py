import sys
import traceback

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from objects import glob
from common.sentry import sentry

try:
	from realistik.user_utils import verify_password
except ImportError:
	# Use ripples one.
	from common.ripple.userUtils import checkLogin as verify_password

MODULE_NAME = "bancho_connect"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/bancho_connect.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncGet(self):
		try:
			# Get request ip
			ip = self.getRequestIP()

			# Argument check
			if not requestsManager.checkArguments(self.request.arguments, ["u", "h"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Get user ID
			username = self.get_argument("u")
			password = self.get_argument("h")
			userID = userUtils.getID(username)
			if userID is None:
				raise exceptions.loginFailedException(MODULE_NAME, username)

			# Check login
			log.info("{} ({}) wants to connect".format(username, userID))
			if not verify_password(userID, password):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			if not userUtils.checkBanchoSession(userID, ip):
				raise exceptions.noBanchoSessionException(MODULE_NAME, username, ip)

			# Ban check
			if userUtils.isBanned(userID):
				raise exceptions.userBannedException(MODULE_NAME, username)

			# Lock check
			if userUtils.isLocked(userID):
				raise exceptions.userLockedException(MODULE_NAME, username)

			# Update latest activity
			userUtils.updateLatestActivity(userID)

			# Get country and output it
			country = glob.db.fetch("SELECT country FROM users_stats WHERE id = %s", [userID])["country"]
			self.write(country)
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			self.write("error: pass\n")
		except exceptions.userBannedException:
			pass
		except exceptions.userLockedException:
			pass
		except exceptions.need2FAException:
			self.write("error: verify\n")
