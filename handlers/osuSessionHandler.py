import os
import json

import tornado.gen
import tornado.web
from common.web import requestsManager
from common.sentry import sentry
	

MODULE_NAME = "osu-session"

class handler(requestsManager.asyncRequestHandler):
	@tornado.web.asynchronous
	@tornado.gen.engine
	@sentry.captureTornado
	def asyncPost(self): self.write("ok")