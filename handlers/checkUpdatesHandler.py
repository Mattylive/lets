from urllib.parse import urlencode

import requests
import tornado.gen
import tornado.web

from common.log import logUtils as log
from common.web import requestsManager


class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	def asyncGet(self):
		# Reusing prev code this is a massive botch idc
		args = {}
		if "stream" in self.request.arguments:
			args["stream"] = self.get_argument("stream")
		if "action" in self.request.arguments:
			args["action"] = self.get_argument("action")
		if "time" in self.request.arguments:
			args["time"] = self.get_argument("time")
		# This is how you dont get ratelimited by bancho 101.
		self.add_header("Location", "https://old.ppy.sh/web/check-updates.php?" + urlencode(args))
		self.set_status(302, "Moved Temporarily")
		self.write("")
