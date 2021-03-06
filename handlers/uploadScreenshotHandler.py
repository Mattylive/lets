import imghdr
import os
import sys
import traceback
from imghdr import test_jpeg, test_png

import tornado.gen
import tornado.web
from raven.contrib.tornado import SentryMixin

from common.log import logUtils as log
from common.ripple import userUtils
from common.web import requestsManager
from constants import exceptions
from common import generalUtils
from objects import glob
from common.sentry import sentry

MODULE_NAME = "screenshot"
class handler(requestsManager.asyncRequestHandler):
	"""
	Handler for /web/osu-screenshot.php
	"""
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncPost(self):
		try:
			if glob.debug:
				requestsManager.printArguments(self)

			# Make sure screenshot file was passed
			if "ss" not in self.request.files:
				raise exceptions.invalidArgumentsException(MODULE_NAME)

			# Check user auth because of sneaky people
			if not requestsManager.checkArguments(self.request.arguments, ["u", "p"]):
				raise exceptions.invalidArgumentsException(MODULE_NAME)
			username = self.get_argument("u")
			password = self.get_argument("p")
			ip = self.getRequestIP()
			userID = userUtils.getID(username)
			if not userUtils.checkLogin(userID, password, ip):
				raise exceptions.loginFailedException(MODULE_NAME, username)
			if userUtils.check2FA(userID, ip):
				raise exceptions.need2FAException(MODULE_NAME, username, ip)

			# Rate limit
			if glob.redis.get("lets:screenshot:{}".format(userID)) is not None:
				return self.write("no")
			glob.redis.set("lets:screenshot:{}".format(userID), 1, 60)

			# Get a random screenshot id
			found = False
			screenshotID = ""
			while not found:
				screenshotID = generalUtils.randomString(8)
				if not os.path.isfile("{}/{}.jpg".format(glob.conf.config["server"]["screenshotspath"], screenshotID)):
					found = True
			
			# Check if the filesize is not ridiculous. Through my checking I
			# have discovered all screenshots on rosu are below 500kb.
			if sys.getsizeof(self.request.files["ss"][0]["body"]) > 500000:
				return self.write("filesize")
			
			# Check if the file contents are actually fine (stop them uploading eg videos).
			if (not test_jpeg(self.request.files["ss"][0]["body"], 0))\
			and (not test_png(self.request.files["ss"][0]["body"], 0)):
				return self.write("unknownfiletype")

			# Write screenshot file to screenshots folder
			with open("{}/{}.jpg".format(glob.conf.config["server"]["screenshotspath"], screenshotID), "wb") as f:
				f.write(self.request.files["ss"][0]["body"])

			# Output
			log.info("New screenshot ({})".format(screenshotID))

			# Return screenshot link
			self.write("{}/ss/{}.jpg".format(glob.conf.config["server"]["serverurl"], screenshotID))
		except exceptions.need2FAException:
			pass
		except exceptions.invalidArgumentsException:
			pass
		except exceptions.loginFailedException:
			pass